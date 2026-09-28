{-# LANGUAGE OverloadedStrings #-}
module Connection
  ( ConnectionEvent(..), ConnectionPhase(..), RoomConnection(..)
  , roomConnection, transmitCommands ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (eitherDecodeStrict')
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHCJS.Types (JSVal)
import Reflex.Dom hiding (now)
import Bindings
import Model
import Protocol

data ConnectionEvent = Connected | Ready | Disconnected | Snapshot RoomState | ConnectionError Text
data Connection = Connection
  { sendCommand :: ClientCommand -> IO (), serverNow :: IO Double, roomReady :: IO Bool }
data Session = Session
  { generation :: Int, socket :: Maybe JSVal, calibrated :: Bool, clockOffset :: Double
  , samples :: [ClockSample], pending :: Maybe Double }

data ConnectionPhase = Connecting | Synchronizing | Online | Retrying
  deriving (Eq, Show)

data RoomConnection t = RoomConnection
  { connectionEvents :: Event t ConnectionEvent
  , connectionPhase :: Dynamic t ConnectionPhase
  , connectionConnected :: Event t ()
  , connectionSnapshots :: Event t RoomState
  , connectionErrors :: Event t Text
  , connectionDisconnected :: Event t ()
  , connectionServerNow :: IO Double
  , connectionSend :: [ClientCommand] -> IO ()
  }

-- The IORef here is a resource boundary: it identifies the live WebSocket used
-- by outgoing effects. Room and presentation state live in the Reflex network.
roomConnection :: MonadWidget t m => m (RoomConnection t)
roomConnection = do
  (events, emit) <- newTriggerEvent
  transport <- liftIO $ newIORef Nothing
  getPostBuild >>= performEvent_ . fmap (const $ liftIO $ afterMount $ connectRoom emit >>= writeIORef transport . Just)
  phase <- foldDyn phaseAfter Connecting events
  pure RoomConnection
    { connectionEvents = events
    , connectionPhase = phase
    , connectionConnected = () <$ ffilter isConnected events
    , connectionSnapshots = fmapMaybe snapshot events
    , connectionErrors = fmapMaybe connectionError events
    , connectionDisconnected = () <$ ffilter isDisconnected events
    , connectionServerNow = maybe now serverNow =<< readIORef transport
    , connectionSend = sendBatch transport
    }
  where
    sendBatch ref batch = readIORef ref >>= maybe (pure ()) (\connection -> mapM_ (sendCommand connection) batch)
    snapshot event = case event of
      Snapshot state -> Just state
      _ -> Nothing
    connectionError event = case event of
      ConnectionError message -> Just message
      _ -> Nothing
    isDisconnected event = case event of
      Disconnected -> True
      _ -> False
    isConnected event = case event of
      Connected -> True
      _ -> False

transmitCommands :: MonadWidget t m
  => RoomConnection t -> Event t [ClientCommand] -> m ()
transmitCommands connection outgoing =
  performEvent_ $ liftIO . connectionSend connection <$> outgoing

phaseAfter :: ConnectionEvent -> ConnectionPhase -> ConnectionPhase
phaseAfter event previous = case event of
  Connected -> Synchronizing
  Ready -> Online
  Disconnected -> Retrying
  Snapshot _ -> previous
  ConnectionError _ -> previous

-- Every callback carries its connection generation. Replaced sockets cannot mutate state.
connectRoom :: (ConnectionEvent -> IO ()) -> IO Connection
connectRoom emit = do
  ref <- newIORef $ Session 0 Nothing False 0 [] Nothing
  let send command = case encodeCommand command of
        Left err -> emit $ ConnectionError err
        Right bytes -> do
          current <- readIORef ref
          case socket current of
            Nothing -> pure ()
            Just ws -> do
              open <- socketOpen ws
              if open then socketSend ws (toJS $ TE.decodeUtf8 $ BL.toStrict bytes) else pure ()
      alive version action = do
        current <- readIORef ref
        if generation current == version then action else pure ()
      ping version = do
        sent <- now
        modifyIORef' ref $ \s -> s { pending = Just sent }
        send (Ping sent)
        void $ forkIO $ do
          threadDelay 5000000
          alive version $ do
            current <- readIORef ref
            if pending current == Just sent then closeCurrent current else pure ()
      closeCurrent current = case socket current of
        Just ws -> socketClose ws
        Nothing -> pure ()
      acceptPong version sent server = do
        current <- readIORef ref
        received <- now
        case (pending current == Just sent, clockSample sent received server) of
          (True, Just sample) -> do
            let collected = samples current ++ [sample]
            modifyIORef' ref $ \s -> s { samples = collected, pending = Nothing }
            if length collected < 5 then ping version else case bestClockSample collected of
              Nothing -> emit $ ConnectionError "Clock sampling failed."
              Just best -> do
                modifyIORef' ref $ \s -> s { clockOffset = offset best, calibrated = True }
                if calibrated current then pure () else emit Ready
          _ -> pure ()
      message version bytes = alive version $ case eitherDecodeStrict' (TE.encodeUtf8 bytes) of
        Left err -> emit $ ConnectionError $ "Invalid server message: " <> T.pack err
        Right value -> case value of
          StateSnapshot state -> emit (Snapshot state)
          Pong sent server -> acceptPong version sent server
          ServerError code description -> emit $ ConnectionError $ code <> ": " <> description
      open = do
        previous <- readIORef ref
        let version = generation previous + 1
        writeIORef ref $ Session version Nothing False 0 [] Nothing
        ws <- connectSocket
          (alive version $ emit Connected >> ping version)
          (message version)
          (alive version $ do
            modifyIORef' ref $ \s -> s { generation = version + 1, calibrated = False, socket = Nothing, pending = Nothing }
            emit Disconnected
            void $ forkIO $ threadDelay 2000000 >> alive (version + 1) open)
        modifyIORef' ref $ \s -> s { socket = Just ws }
  void $ forkIO $ forever $ do
    threadDelay 30000000
    current <- readIORef ref
    case (socket current, pending current) of
      (Just ws, Nothing) -> do
        connected <- socketOpen ws
        if connected then do
          modifyIORef' ref $ \s -> s { samples = [] }
          ping (generation current)
        else pure ()
      _ -> pure ()
  open
  pure $ Connection send (do s <- readIORef ref; t <- now; pure (t + clockOffset s)) (calibrated <$> readIORef ref)
