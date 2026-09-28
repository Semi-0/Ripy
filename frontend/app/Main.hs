{-# LANGUAGE OverloadedStrings, RecursiveDo #-}
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
app = mdo
  catalogState <- catalogNetwork
  roomLink <- roomConnection outgoing
  (room, accepted) <- acceptSnapshots
    (connectionConnected roomLink)
    (connectionSnapshots roomLink)

  let reactions = concatMap reactIntent <$> intentions
      desiredPlayback = playbackStates (connectionPhase roomLink) room accepted
      videoInputs = VideoInputs
        { videoStates = desiredPlayback
        , videoDisconnects = connectionDisconnected roomLink
        , videoEnableRequests = () <$ reactionEvent enableReaction reactions
        , videoFullscreenRequests = () <$ reactionEvent fullscreenReaction reactions
        , videoVolumes = reactionEvent volumeReaction reactions
        }

  player <- videoController
    (catalogMovies <$> catalogState)
    (connectionServerNow roomLink)
    videoInputs

  let outgoing = mergeWith (++) [commands reactions, playerMediaCommands player]
      externalErrors = leftmost
        [ catalogErrors catalogState
        , connectionErrors roomLink
        , reactionEvent rejectedReaction reactions
        ]
      errorChanges = leftmost [Just <$> externalErrors, Nothing <$ accepted]

  latestError <- holdDyn Nothing errorChanges
  let ui = deriveUi
        <$> catalogState
        <*> connectionPhase roomLink
        <*> room
        <*> playerState player
        <*> latestError
  intentions <- movieView ui
  pure ()

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
