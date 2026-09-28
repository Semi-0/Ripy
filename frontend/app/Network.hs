{-# LANGUAGE OverloadedStrings #-}
module Network where

import Control.Monad.Fix (MonadFix)
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)
import Reflex
import Model (acceptSnapshot)
import Protocol hiding (SelectMovie)
import qualified Protocol as Protocol
import View (Intent(..), Ui(..))
import Catalog (CatalogState, catalogMovies)
import Connection (ConnectionPhase(..))
import Player (PlayerState(..))

data Reaction
  = SendCommand ClientCommand
  | SetVolume Double
  | EnableVideo
  | ToggleFullscreen
  | RejectIntent Text
  deriving (Eq, Show)

data SnapshotInput = ResetSnapshots | ReceiveSnapshot RoomState

acceptSnapshots :: (Reflex t, MonadHold t m, MonadFix m)
  => Event t () -> Event t RoomState
  -> m (Dynamic t (Maybe RoomState), Event t RoomState)
acceptSnapshots resets incoming = do
  room <- foldDynMaybe transition Nothing $ leftmost
    [ResetSnapshots <$ resets, ReceiveSnapshot <$> incoming]
  pure (room, fmapMaybe id $ updated room)
  where
    transition input current = case input of
      ResetSnapshots -> Just Nothing
      ReceiveSnapshot candidate -> case acceptSnapshot current candidate of
        Just next | Just next /= current -> Just $ Just next
        _ -> Nothing

playbackStates :: Reflex t
  => Dynamic t ConnectionPhase -> Dynamic t (Maybe RoomState) -> Event t RoomState -> Event t RoomState
playbackStates phase room accepted = leftmost
  [ gate (current $ (== Online) <$> phase) accepted
  , attachPromptlyDynWithMaybe resume room $ ffilter (== Online) $ updated phase
  ]
  where
    resume snapshot _ = snapshot

reactIntent :: Intent -> [Reaction]
reactIntent intent = case intent of
  SelectMovie ident -> [SendCommand $ Protocol.SelectMovie ident]
  Start -> [SendCommand Play]
  Stop -> [SendCommand $ Pause UserPause]
  SeekTo raw -> either (pure . RejectIntent) (pure . SendCommand . Seek . max 0) $ parseNumber "Invalid seek position." raw
  SetLocalVolume raw -> either (pure . RejectIntent) (pure . SetVolume . max 0 . min 1) $ parseNumber "Invalid volume." raw
  Enable -> [EnableVideo]
  Fullscreen -> [ToggleFullscreen]

parseNumber :: Text -> Text -> Either Text Double
parseNumber message raw = case readMaybe $ T.unpack raw of
  Just value | finite value -> Right value
  _ -> Left message

commands :: Reflex t => Event t [Reaction] -> Event t [ClientCommand]
commands = fmapMaybe nonempty . fmap (foldr collect [])
  where
    collect (SendCommand command) rest = command : rest
    collect _ rest = rest
    nonempty [] = Nothing
    nonempty values = Just values

reactionEvent :: Reflex t => (Reaction -> Maybe a) -> Event t [Reaction] -> Event t a
reactionEvent choose = fmapMaybe (firstJust . map choose)
  where
    firstJust = foldr (<|>) Nothing
    (<|>) left right = case left of
      Just value -> Just value
      Nothing -> right

deriveUi :: CatalogState -> ConnectionPhase -> Maybe RoomState -> PlayerState -> Maybe Text -> Ui
deriveUi catalogState phase room player externalError = Ui
  { catalog = catalogMovies catalogState
  , selected = maybe "" (maybe "" id . mediaId) room
  , connectionLabel = phaseLabel phase
  , ready = phase == Online
  , playable = playerPlayable player
  , statusLabel = statusFor phase player
  , errorLabel = maybe (playerError player) id externalError
  , needsEnable = playerNeedsEnable player
  , timeLabel = playerTimeLabel player
  , fullscreenActive = playerFullscreen player
  }

phaseLabel :: ConnectionPhase -> Text
phaseLabel phase = case phase of
  Connecting -> "Connecting…"
  Synchronizing -> "Synchronizing clock…"
  Online -> "Connected · one room"
  Retrying -> "Disconnected · retrying"

statusFor :: ConnectionPhase -> PlayerState -> Text
statusFor phase player = case phase of
  Retrying -> "Playback paused locally. Reconnecting…"
  _ -> playerStatus player
