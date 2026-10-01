{-# LANGUAGE OverloadedStrings #-}
module Main where

import Data.Text (Text)
import qualified Data.Text as T
import Reflex.Dom hiding (Pause)
import Text.Read (readMaybe)
import Catalog
import Connection
import Ducking
import MovieView
import MediaManagement
import MediaManagementView
import MediaTransfer
import Network
import Player
import Protocol hiding (SelectMovie)
import qualified Protocol as Protocol
import View
import Voice
import VoiceView

main :: IO ()
main = mainWidget app

-- Main is the specialization boundary. Views emit generic interaction signals;
-- only this composition assigns movie commands and browser reactions to them.
app :: MonadWidget t m => m ()
app = do
  (mediaManagement, controlMediaManagement) <- mediaManagementController
  catalogState <- catalogNetwork $ mediaCatalogChanged mediaManagement
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
  (voice, controlVoice) <- voiceController
  (signals, mediaSignals, voiceSignals) <- elAttr "main" ("data-reflex-ready" =: "true") $ do
    movieSignals <- movieView presentation
    managementSignals <- mediaManagementView $ mediaManagementPresentation
      <$> mediaManagementState mediaManagement
      <*> catalogState
    callSignals <- voiceView $ voicePresentation <$> voiceState voice
    el "footer" $ text
      "Movie controls are shared. Volume and voice mute are local. Voice travels directly between the two browsers."
    pure (movieSignals, managementSignals, callSignals)

  let reactions = specializeMovieSignals signals
  baseVolume <- holdDyn 1 $ reactionEvent volumeReaction reactions
  effectiveVolume <- holdUniqDyn $ zipDynWith
    (effectiveMovieVolume defaultDuckingPolicy)
    baseVolume
    (voiceRemoteSpeaking voice)
  let desiredPlayback = playbackStates (connectionPhase roomLink) room accepted
      videoInputs = VideoInputs
        { videoStates = desiredPlayback
        , videoDisconnects = connectionDisconnected roomLink
        , videoEnableRequests = () <$ reactionEvent enableReaction reactions
        , videoFullscreenRequests = () <$ reactionEvent fullscreenReaction reactions
        , videoVolumes = updated effectiveVolume
        , videoErrors = reactionEvent rejectedReaction reactions
        }
      outgoing = mergeWith (++) [commands reactions, playerMediaCommands player]
  controlVideo videoInputs
  transmitCommands roomLink outgoing
  controlMediaManagement MediaManagementInputs
    { uploadRequests = uploadPressed mediaSignals
    , adminUnlockRequests = unlockSubmitted mediaSignals
    , adminLogoutRequests = logoutPressed mediaSignals
    , adminDeleteRequests = deletePressed mediaSignals
    }
  let muteRequests = attachPromptlyDynWith
        (\state _ -> not $ voiceMuted state)
        (voiceState voice)
        (mutePressed voiceSignals)
  controlVoice VoiceInputs
    { voiceJoinRequests = joinPressed voiceSignals
    , voiceLeaveRequests = leavePressed voiceSignals
    , voiceMuteRequests = muteRequests
    , voiceEnableRequests = enableAudioPressed voiceSignals
    }

mediaManagementPresentation
  :: MediaManagementState -> CatalogState -> MediaManagementViewModel
mediaManagementPresentation state catalog = MediaManagementViewModel
  { uploadButton = ButtonView ("id" =: "media-upload") label enabled
  , uploadProgress = progress
  , adminConfigured = adminEnabled access
  , adminUnlocked = deleteAllowed access
  , adminStatusText = administratorStatus access
  , deleteOptions = map movieOption $ catalogMovies catalog
  , managementMessage = mediaMessage state
  }
  where
    access = mediaAccess state
    (label, enabled, progress) = case mediaTransfer state of
      TransferIdle -> ("Upload movie", uploadAllowed access, Nothing)
      Uploading amount -> ("Uploading…", False, Just amount)
      TransferFailed _ -> ("Retry upload", uploadAllowed access, Nothing)
    movieOption movie = (movieId movie, movieTitle movie)

administratorStatus :: MediaAccess -> Text
administratorStatus access = case deleteAllowed access of
  True -> "Administrator deletion is unlocked for this browser."
  False -> case adminEnabled access of
    True -> "Enter the server administrator password to unlock deletion."
    False -> "Deletion is disabled. Set MEDIA_ADMIN_PASSWORD on the server and restart Ripy."

voicePresentation :: VoiceState -> VoiceViewModel
voicePresentation state = VoiceViewModel
  { joinButton = ButtonView ("id" =: "voice-join") "Join voice" $ canJoin phase
  , leaveButton = ButtonView ("id" =: "voice-leave") "Leave voice" $ isActive phase
  , muteButton = ButtonView
      (("id" =: "voice-mute") <> ("aria-pressed" =: pressed (voiceMuted state)))
      (if voiceMuted state then "Unmute" else "Mute")
      (isActive phase)
  , enableAudioButton = ButtonView
      (visibleAttributes ("id" =: "voice-enable") $ voiceNeedsEnable state)
      "Enable voice audio"
      True
  , voiceStatusText = voicePhaseLabel phase
  , voiceErrorText = voiceErrorMessage state
  }
  where
    phase = voicePhase state
    pressed value = if value then "true" else "false"

canJoin :: VoicePhase -> Bool
canJoin phase = case phase of
  VoiceIdle -> True
  VoiceFailed _ -> True
  VoiceRequestingMicrophone -> False
  VoiceConnecting -> False
  VoiceWaitingForPeer -> False
  VoiceConnected -> False
  VoiceReconnecting -> False

isActive :: VoicePhase -> Bool
isActive phase = case phase of
  VoiceIdle -> False
  VoiceFailed _ -> False
  VoiceRequestingMicrophone -> True
  VoiceConnecting -> True
  VoiceWaitingForPeer -> True
  VoiceConnected -> True
  VoiceReconnecting -> True

voicePhaseLabel :: VoicePhase -> Text
voicePhaseLabel phase = case phase of
  VoiceIdle -> "OFFLINE"
  VoiceRequestingMicrophone -> "REQUESTING MICROPHONE"
  VoiceConnecting -> "CONNECTING"
  VoiceWaitingForPeer -> "WAITING FOR FRIEND"
  VoiceConnected -> "CONNECTED"
  VoiceReconnecting -> "RECONNECTING"
  VoiceFailed _ -> "FAILED"

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
