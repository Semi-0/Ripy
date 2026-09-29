{-# LANGUAGE OverloadedStrings #-}
module Main where

import Data.Text (Text)
import qualified Data.Text as T
import Reflex.Dom hiding (Pause)
import Text.Read (readMaybe)
import Catalog
import Connection
import MovieView
import Network
import Player
import Protocol hiding (SelectMovie)
import qualified Protocol as Protocol

main :: IO ()
main = mainWidget app

-- Main is the specialization boundary. Views emit generic interaction signals;
-- only this composition assigns movie commands and browser reactions to them.
app :: MonadWidget t m => m ()
app = do
  catalogState <- catalogNetwork
  roomLink <- roomConnection
  (room, accepted) <- acceptSnapshots
    (connectionConnected roomLink)
    (connectionSnapshots roomLink)
  (player, controlVideo) <- videoController
    (catalogMovies <$> catalogState)
    (connectionServerNow roomLink)

  let externalErrors = leftmost
        [catalogErrors catalogState, connectionErrors roomLink]
      errorChanges = leftmost [Just <$> externalErrors, Nothing <$ accepted]
  latestError <- holdDyn Nothing errorChanges
  let presentation = moviePresentation
        <$> catalogState
        <*> connectionPhase roomLink
        <*> room
        <*> playerState player
        <*> latestError
  signals <- movieView presentation

  let reactions = specializeMovieSignals signals
      desiredPlayback = playbackStates (connectionPhase roomLink) room accepted
      videoInputs = VideoInputs
        { videoStates = desiredPlayback
        , videoDisconnects = connectionDisconnected roomLink
        , videoEnableRequests = () <$ reactionEvent enableReaction reactions
        , videoFullscreenRequests = () <$ reactionEvent fullscreenReaction reactions
        , videoVolumes = reactionEvent volumeReaction reactions
        , videoErrors = reactionEvent rejectedReaction reactions
        }
      outgoing = mergeWith (++) [commands reactions, playerMediaCommands player]
  controlVideo videoInputs
  transmitCommands roomLink outgoing

specializeMovieSignals :: Reflex t => MovieSignals t -> Event t [Reaction]
specializeMovieSignals signals = mergeWith (++)
  [ pure . SendCommand . Protocol.SelectMovie <$> movieSelected signals
  , [SendCommand Play] <$ playPressed signals
  , [SendCommand $ Pause UserPause] <$ pausePressed signals
  , seekReactions <$> seekChanged signals
  , volumeReactions <$> volumeChanged signals
  , [EnableVideo] <$ enablePressed signals
  , [ToggleFullscreen] <$ fullscreenPressed signals
  ]

seekReactions :: Text -> [Reaction]
seekReactions raw = case parseNumber "Invalid seek position." raw of
  Left message -> [RejectIntent message]
  Right value -> [SendCommand $ Seek $ max 0 value]

volumeReactions :: Text -> [Reaction]
volumeReactions raw = case parseNumber "Invalid volume." raw of
  Left message -> [RejectIntent message]
  Right value -> [SetVolume $ max 0 $ min 1 value]

parseNumber :: Text -> Text -> Either Text Double
parseNumber message raw = case readMaybe $ T.unpack raw of
  Just value | finite value -> Right value
  _ -> Left message

moviePresentation
  :: CatalogState
  -> ConnectionPhase
  -> Maybe RoomState
  -> PlayerState
  -> Maybe Text
  -> MovieViewModel
moviePresentation catalogState phase room player externalError = MovieViewModel
  { movieOptions = map toMovieOption $ catalogMovies catalogState
  , selectedMovieId = maybe "" (maybe "" id . mediaId) room
  , connectionText = phaseLabel phase
  , controlsReady = phase == Online
  , moviePlayable = playerPlayable player
  , statusText = statusFor phase player
  , errorText = maybe (playerError player) id externalError
  , enableVisible = playerNeedsEnable player
  , timeText = playerTimeLabel player
  , fullscreenActive = playerFullscreen player
  }
  where
    toMovieOption movie = MovieOption (movieId movie) (movieTitle movie)

phaseLabel :: ConnectionPhase -> Text
phaseLabel phase = case phase of
  Connecting -> "Connecting…"
  Synchronizing -> "Synchronizing clock…"
  Online -> "Connected · one room"
  Retrying -> "Disconnected · retrying"

statusFor :: ConnectionPhase -> PlayerState -> Text
statusFor phase player = case phase of
  Connecting -> playerStatus player
  Synchronizing -> playerStatus player
  Online -> playerStatus player
  Retrying -> "Playback paused locally. Reconnecting…"

enableReaction :: Reaction -> Maybe ()
enableReaction reaction = case reaction of
  EnableVideo -> Just ()
  SendCommand _ -> Nothing
  SetVolume _ -> Nothing
  ToggleFullscreen -> Nothing
  RejectIntent _ -> Nothing

fullscreenReaction :: Reaction -> Maybe ()
fullscreenReaction reaction = case reaction of
  ToggleFullscreen -> Just ()
  SendCommand _ -> Nothing
  SetVolume _ -> Nothing
  EnableVideo -> Nothing
  RejectIntent _ -> Nothing

volumeReaction :: Reaction -> Maybe Double
volumeReaction reaction = case reaction of
  SetVolume value -> Just value
  SendCommand _ -> Nothing
  EnableVideo -> Nothing
  ToggleFullscreen -> Nothing
  RejectIntent _ -> Nothing

rejectedReaction :: Reaction -> Maybe Text
rejectedReaction reaction = case reaction of
  RejectIntent message -> Just message
  SendCommand _ -> Nothing
  SetVolume _ -> Nothing
  EnableVideo -> Nothing
  ToggleFullscreen -> Nothing
