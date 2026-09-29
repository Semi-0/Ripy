{-# LANGUAGE OverloadedStrings #-}
module Main where

import Data.Text (Text)
import Reflex.Dom hiding (Pause)
import Catalog
import Connection
import Network
import Player
import View

main :: IO ()
main = mainWidget app

-- The application is one recursive signal graph. Events describe intentions and
-- observations; the only held values here are accepted room state and display
-- errors. WebSocket and media resources remain isolated in their adapters.
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
  let ui = deriveUi
        <$> catalogState
        <*> connectionPhase roomLink
        <*> room
        <*> playerState player
        <*> latestError
  intentions <- movieView ui

  let reactions = concatMap reactIntent <$> intentions
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

enableReaction :: Reaction -> Maybe ()
enableReaction reaction = case reaction of
  EnableVideo -> Just ()
  _ -> Nothing

fullscreenReaction :: Reaction -> Maybe ()
fullscreenReaction reaction = case reaction of
  ToggleFullscreen -> Just ()
  _ -> Nothing

volumeReaction :: Reaction -> Maybe Double
volumeReaction reaction = case reaction of
  SetVolume value -> Just value
  _ -> Nothing

rejectedReaction :: Reaction -> Maybe Text
rejectedReaction reaction = case reaction of
  RejectIntent message -> Just message
  _ -> Nothing
