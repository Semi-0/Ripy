{-# LANGUAGE OverloadedStrings #-}
module Network where

import Control.Monad.Fix (MonadFix)
import Data.Text (Text)
import Reflex
import Connection (ConnectionPhase(..))
import Model (acceptSnapshot)
import Protocol

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
  => Dynamic t ConnectionPhase
  -> Dynamic t (Maybe RoomState)
  -> Event t RoomState
  -> Event t RoomState
playbackStates phase room accepted = leftmost
  [ gate (current $ (== Online) <$> phase) accepted
  , attachPromptlyDynWithMaybe resume room $ ffilter (== Online) $ updated phase
  ]
  where
    resume snapshot _ = snapshot

commands :: Reflex t => Event t [Reaction] -> Event t [ClientCommand]
commands = fmapMaybe nonempty . fmap (foldr collect [])
  where
    collect reaction rest = case reaction of
      SendCommand command -> command : rest
      SetVolume _ -> rest
      EnableVideo -> rest
      ToggleFullscreen -> rest
      RejectIntent _ -> rest
    nonempty values = case values of
      [] -> Nothing
      _ -> Just values

reactionEvent :: Reflex t
  => (Reaction -> Maybe a) -> Event t [Reaction] -> Event t a
reactionEvent choose = fmapMaybe (firstJust . map choose)
  where
    firstJust = foldr prefer Nothing
    prefer left right = case left of
      Just value -> Just value
      Nothing -> right
