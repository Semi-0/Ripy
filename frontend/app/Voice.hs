{-# LANGUAGE FlexibleContexts, OverloadedStrings #-}
module Voice
  ( VoicePhase(..), VoiceState(..), VoiceInputs(..), VoiceNetwork(..)
  , voiceController
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forM_, void)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (eitherDecodeStrict', encode)
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHCJS.Types (JSVal)
import Reflex.Dom
import Bindings
import VoiceBindings
import VoiceProtocol

data VoicePhase
  = VoiceIdle
  | VoiceRequestingMicrophone
  | VoiceConnecting
  | VoiceWaitingForPeer
  | VoiceConnected
  | VoiceReconnecting
  | VoiceFailed Text
  deriving (Eq, Show)

data VoiceState = VoiceState
  { voicePhase :: VoicePhase
  , voiceMuted :: Bool
  , voiceNeedsEnable :: Bool
  , voiceErrorMessage :: Text
  } deriving (Eq, Show)

data VoiceInputs t = VoiceInputs
  { voiceJoinRequests :: Event t ()
  , voiceLeaveRequests :: Event t ()
  , voiceMuteRequests :: Event t Bool
  , voiceEnableRequests :: Event t ()
  }

data VoiceNetwork t = VoiceNetwork
  { voiceState :: Dynamic t VoiceState
  }

data VoiceIntent = JoinVoice | LeaveVoice | SetVoiceMuted Bool | EnableVoiceAudio
data VoiceEvent
  = SetVoicePhase VoicePhase
  | SetMuted Bool
  | SetNeedsEnable Bool
  | SetVoiceError Text

data VoiceRuntime = VoiceRuntime
  { runtimeGeneration :: Int
  , runtimeJoined :: Bool
  , runtimeMuted :: Bool
  , runtimeConfiguration :: Maybe Text
  , runtimeStream :: Maybe JSVal
  , runtimePeer :: Maybe BrowserPeer
  , runtimeSocket :: Maybe JSVal
  , runtimeRemoteReady :: Bool
  , runtimePendingIce :: [IceCandidate]
  }

initialVoiceState :: VoiceState
initialVoiceState = VoiceState VoiceIdle False False ""

initialRuntime :: VoiceRuntime
initialRuntime = VoiceRuntime 0 False False Nothing Nothing Nothing Nothing False []

voiceStateAfter :: VoiceEvent -> VoiceState -> VoiceState
voiceStateAfter event previous = case event of
  SetVoicePhase phase -> previous { voicePhase = phase }
  SetMuted muted -> previous { voiceMuted = muted }
  SetNeedsEnable needed -> previous { voiceNeedsEnable = needed }
  SetVoiceError message -> previous { voiceErrorMessage = message }

voiceController :: MonadWidget t m => m (VoiceNetwork t, VoiceInputs t -> m ())
voiceController = do
  (events, emit) <- newTriggerEvent
  runtime <- liftIO $ newIORef initialRuntime
  state <- foldDyn voiceStateAfter initialVoiceState events
  let control inputs = performEvent_ $ fmap (liftIO . applyIntent runtime emit) $
        mergeWith (++)
          [ [JoinVoice] <$ voiceJoinRequests inputs
          , [LeaveVoice] <$ voiceLeaveRequests inputs
          , (: []) . SetVoiceMuted <$> voiceMuteRequests inputs
          , [EnableVoiceAudio] <$ voiceEnableRequests inputs
          ]
  pure (VoiceNetwork state, control)

applyIntent :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> [VoiceIntent] -> IO ()
applyIntent runtime emit = mapM_ apply
  where
    apply intent = case intent of
      JoinVoice -> joinVoice runtime emit
      LeaveVoice -> leaveVoice runtime emit
      SetVoiceMuted muted -> muteVoice runtime emit muted
      EnableVoiceAudio -> enableVoiceAudio $ either
        (\message -> emit (SetVoiceError message) >> emit (SetNeedsEnable True))
        (const $ emit (SetVoiceError "") >> emit (SetNeedsEnable False))

joinVoice :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> IO ()
joinVoice runtime emit = do
  previous <- readIORef runtime
  case runtimeJoined previous of
    True -> pure ()
    False -> do
      let version = runtimeGeneration previous + 1
      writeIORef runtime initialRuntime
        { runtimeGeneration = version
        , runtimeJoined = True
        , runtimeMuted = runtimeMuted previous
        }
      emit $ SetVoicePhase VoiceRequestingMicrophone
      emit $ SetNeedsEnable False
      emit $ SetVoiceError ""
      fetchVoiceIce $ alive runtime version . either
        (failVoice runtime emit)
        (acquireMicrophone runtime emit version)

acquireMicrophone
  :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> Int -> Text -> IO ()
acquireMicrophone runtime emit version configuration =
  case eitherDecodeStrict' (TE.encodeUtf8 configuration) :: Either String VoiceIceResponse of
    Left message -> failVoice runtime emit $ "Invalid voice configuration: " <> T.pack message
    Right _ -> requestVoiceMedia $ alive runtime version . either
      (failVoice runtime emit)
      (\stream -> do
        setVoiceMuted stream True
        modifyIORef' runtime $ \current -> current
          { runtimeConfiguration = Just configuration
          , runtimeStream = Just stream
          }
        openVoiceSocket runtime emit version)

openVoiceSocket :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> Int -> IO ()
openVoiceSocket runtime emit version = do
  emit $ SetVoicePhase VoiceConnecting
  socketValue <- connectSocketAt "/voice"
    (alive runtime version $ pure ())
    (alive runtime version . receiveVoice runtime emit version)
    (alive runtime version $ reconnectVoice runtime emit version)
  current <- readIORef runtime
  case runtimeGeneration current == version && runtimeJoined current of
    True -> modifyIORef' runtime $ \value -> value { runtimeSocket = Just socketValue }
    False -> socketClose socketValue

receiveVoice :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> Int -> Text -> IO ()
receiveVoice runtime emit version bytes =
  case eitherDecodeStrict' (TE.encodeUtf8 bytes) of
    Left message -> failVoice runtime emit $
      "Invalid voice message: " <> T.pack message
    Right message -> handleVoiceMessage runtime emit version message

handleVoiceMessage
  :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> Int -> VoiceServerMessage -> IO ()
handleVoiceMessage runtime emit version message = case message of
  VoiceProtocol.VoiceWaiting -> emit $ SetVoicePhase VoiceWaitingForPeer
  VoicePeerReady role -> startPeer runtime emit version role
  VoiceOfferReceived sdp -> withPeer runtime emit $ \peer ->
    answerVoiceOffer peer sdp $ alive runtime version . either
      (failVoice runtime emit)
      (\answer -> markRemoteReady runtime emit version >>
        sendVoice runtime emit (VoiceAnswer answer))
  VoiceAnswerReceived sdp -> withPeer runtime emit $ \peer ->
    acceptVoiceAnswer peer sdp $ alive runtime version . either
      (failVoice runtime emit)
      (const $ markRemoteReady runtime emit version)
  VoiceIceReceived candidateValue -> receiveIce runtime emit version candidateValue
  VoicePeerLeft -> peerLeft runtime emit
  VoiceServerError code messageText ->
    failVoice runtime emit $ code <> ": " <> messageText

startPeer
  :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> Int -> VoiceRole -> IO ()
startPeer runtime emit version role = do
  current <- readIORef runtime
  case (runtimeConfiguration current, runtimeStream current) of
    (Just configuration, Just stream) -> do
      forM_ (runtimePeer current) closeVoicePeer
      peer <- createVoicePeer configuration stream
        (sendCandidate runtime emit version)
        (alive runtime version . either
          (\message -> emit (SetVoiceError message) >> emit (SetNeedsEnable True))
          (const $ emit (SetVoiceError "") >> emit (SetNeedsEnable False)))
        (alive runtime version . peerStateChanged runtime emit version)
      modifyIORef' runtime $ \value -> value
        { runtimePeer = Just peer
        , runtimeRemoteReady = False
        , runtimePendingIce = []
        }
      setVoiceMuted stream $ runtimeMuted current
      emit $ SetVoicePhase VoiceConnecting
      case role of
        Offerer -> makeVoiceOffer peer $ alive runtime version . either
          (failVoice runtime emit)
          (sendVoice runtime emit . VoiceOffer)
        Answerer -> pure ()
    _ -> failVoice runtime emit "Voice resources are unavailable."

sendCandidate
  :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> Int -> Text -> IO ()
sendCandidate runtime emit version raw = alive runtime version $
  case eitherDecodeStrict' (TE.encodeUtf8 raw) of
    Left message -> failVoice runtime emit $
      "Invalid local ICE candidate: " <> T.pack message
    Right candidateValue -> sendVoice runtime emit $ VoiceIce candidateValue

receiveIce
  :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> Int -> IceCandidate -> IO ()
receiveIce runtime emit version candidateValue = do
  current <- readIORef runtime
  case (runtimePeer current, runtimeRemoteReady current) of
    (Just peer, True) -> addCandidate runtime emit version peer candidateValue
    _ -> modifyIORef' runtime $ \value ->
      value { runtimePendingIce = runtimePendingIce value ++ [candidateValue] }

markRemoteReady :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> Int -> IO ()
markRemoteReady runtime emit version = do
  current <- readIORef runtime
  modifyIORef' runtime $ \value ->
    value { runtimeRemoteReady = True, runtimePendingIce = [] }
  case runtimePeer current of
    Nothing -> pure ()
    Just peer -> forM_ (runtimePendingIce current) $
      addCandidate runtime emit version peer

addCandidate
  :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> Int
  -> BrowserPeer -> IceCandidate -> IO ()
addCandidate runtime emit version peer candidateValue =
  addVoiceCandidate peer (candidateJson candidateValue) $
    alive runtime version . either
      (failVoice runtime emit)
      (const $ pure ())

candidateJson :: IceCandidate -> Text
candidateJson = TE.decodeUtf8 . BL.toStrict . encode

sendVoice :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> VoiceSignal -> IO ()
sendVoice runtime emit signal = case encodeVoiceSignal signal of
  Left message -> failVoice runtime emit message
  Right bytes -> do
    current <- readIORef runtime
    case runtimeSocket current of
      Nothing -> pure ()
      Just socketValue -> do
        open <- socketOpen socketValue
        case open of
          True -> socketSend socketValue $ toJS $ TE.decodeUtf8 $ BL.toStrict bytes
          False -> pure ()

withPeer
  :: IORef VoiceRuntime -> (VoiceEvent -> IO ())
  -> (BrowserPeer -> IO ()) -> IO ()
withPeer runtime emit operation = do
  current <- readIORef runtime
  case runtimePeer current of
    Just peer -> operation peer
    Nothing -> failVoice runtime emit "Voice peer is unavailable."

peerStateChanged
  :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> Int -> Text -> IO ()
peerStateChanged runtime emit version state = case state of
  "connected" -> emit $ SetVoicePhase VoiceConnected
  "failed" -> reconnectVoice runtime emit version
  "disconnected" -> reconnectVoice runtime emit version
  "new" -> emit $ SetVoicePhase VoiceConnecting
  "connecting" -> emit $ SetVoicePhase VoiceConnecting
  "closed" -> pure ()
  _ -> failVoice runtime emit $ "Unknown WebRTC state: " <> state

peerLeft :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> IO ()
peerLeft runtime emit = do
  current <- readIORef runtime
  forM_ (runtimePeer current) closeVoicePeer
  forM_ (runtimeStream current) $ \stream -> setVoiceMuted stream True
  clearVoiceAudio
  modifyIORef' runtime $ \value -> value
    { runtimePeer = Nothing
    , runtimeRemoteReady = False
    , runtimePendingIce = []
    }
  emit $ SetVoicePhase VoiceWaitingForPeer
  emit $ SetNeedsEnable False
  emit $ SetVoiceError ""

reconnectVoice
  :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> Int -> IO ()
reconnectVoice runtime emit version = do
  current <- readIORef runtime
  case runtimeGeneration current == version && runtimeJoined current of
    False -> pure ()
    True -> do
      let nextVersion = version + 1
      writeIORef runtime current
        { runtimeGeneration = nextVersion
        , runtimePeer = Nothing
        , runtimeSocket = Nothing
        , runtimeRemoteReady = False
        , runtimePendingIce = []
        }
      forM_ (runtimePeer current) closeVoicePeer
      forM_ (runtimeSocket current) socketClose
      forM_ (runtimeStream current) $ \stream -> setVoiceMuted stream True
      clearVoiceAudio
      emit $ SetVoicePhase VoiceReconnecting
      emit $ SetVoiceError ""
      void $ forkIO $ do
        threadDelay 2000000
        alive runtime nextVersion $ openVoiceSocket runtime emit nextVersion

muteVoice :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> Bool -> IO ()
muteVoice runtime emit muted = do
  current <- readIORef runtime
  modifyIORef' runtime $ \value -> value { runtimeMuted = muted }
  case (runtimePeer current, runtimeStream current) of
    (Just _, Just stream) -> setVoiceMuted stream muted
    _ -> pure ()
  emit $ SetMuted muted

leaveVoice :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> IO ()
leaveVoice runtime emit = terminateVoice runtime
  >> emit (SetVoicePhase VoiceIdle)
  >> emit (SetMuted False)
  >> emit (SetNeedsEnable False)
  >> emit (SetVoiceError "")

failVoice :: IORef VoiceRuntime -> (VoiceEvent -> IO ()) -> Text -> IO ()
failVoice runtime emit message = terminateVoice runtime
  >> emit (SetVoicePhase $ VoiceFailed message)
  >> emit (SetMuted False)
  >> emit (SetNeedsEnable False)
  >> emit (SetVoiceError message)

terminateVoice :: IORef VoiceRuntime -> IO ()
terminateVoice runtime = do
  current <- readIORef runtime
  let next = initialRuntime { runtimeGeneration = runtimeGeneration current + 1 }
  writeIORef runtime next
  sendBeforeClose current
  forM_ (runtimePeer current) closeVoicePeer
  forM_ (runtimeSocket current) socketClose
  forM_ (runtimeStream current) stopVoiceMedia
  clearVoiceAudio
  where
    sendBeforeClose current = case runtimeSocket current of
      Nothing -> pure ()
      Just socketValue -> case encodeVoiceSignal VoiceLeave of
        Left _ -> pure ()
        Right bytes -> do
          open <- socketOpen socketValue
          case open of
            True -> socketSend socketValue $ toJS $ TE.decodeUtf8 $ BL.toStrict bytes
            False -> pure ()

alive :: IORef VoiceRuntime -> Int -> IO () -> IO ()
alive runtime version action = do
  current <- readIORef runtime
  case runtimeJoined current && runtimeGeneration current == version of
    True -> action
    False -> pure ()
