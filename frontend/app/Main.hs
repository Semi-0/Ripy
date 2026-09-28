{-# LANGUAGE OverloadedStrings, RecursiveDo #-}
module Main where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (eitherDecodeStrict')
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Text.Read (readMaybe)
import Reflex.Dom
import qualified Bindings as B
import Connection
import Model (acceptSnapshot, clampPosition)
import Player
import Protocol
import View

main :: IO ()
main = mainWidget $ mdo
  (changes, changeUi) <- newTriggerEvent
  (observations, sendObserved) <- newTriggerEvent
  connectionRef <- liftIO $ newIORef Nothing
  playerRef <- liftIO $ newIORef Nothing
  ui <- foldDyn ($) emptyUi changes
  intentions <- movieView ui
  commands <- performEvent $ ffor intentions $ liftIO . fmap concat . mapM (commandFor playerRef changeUi)
  -- Defined ordering: explicit intentions first, then media observations.
  let outgoing = mergeWith (++) [commands, observations]
  performEvent_ $ ffor outgoing $ \batch -> liftIO $ do
    connection <- readIORef connectionRef
    case connection of
      Just room -> mapM_ (sendCommand room) batch
      Nothing -> pure ()
  postBuild <- getPostBuild
  performEvent_ $ ffor postBuild $ \() -> liftIO $
    initialize connectionRef playerRef changeUi (sendObserved . pure)

commandFor :: IORef (Maybe Player) -> ((Ui -> Ui) -> IO ()) -> Intent -> IO [ClientCommand]
commandFor playerRef change intent = case intent of
  Choose "" -> pure []
  Choose ident -> pure [SelectMovie ident]
  Start -> pure [Play]
  Stop -> pure [Pause UserPause]
  SeekChanged -> do
    value <- B.textProperty "seek" "value"
    duration <- B.numberProperty "video" "duration"
    case readMaybe (T.unpack $ B.fromJS value) of
      Just n | finite n -> pure [Seek $ clampPosition n duration]
      _ -> change (\u -> u { errorLabel = "Invalid seek position." }) >> pure []
  VolumeChanged -> do
    value <- B.textProperty "volume" "value"
    case readMaybe (T.unpack $ B.fromJS value) of
      Just n | finite n -> B.setNumber "video" "volume" (max 0 $ min 1 n) >> pure []
      _ -> change (\u -> u { errorLabel = "Invalid volume." }) >> pure []
  Enable -> do
    player <- readIORef playerRef
    case player of
      Just controller -> enablePlayback controller
      Nothing -> pure ()
    pure []
  Fullscreen -> do
    B.fullscreen $ \err -> case err of
      "" -> pure ()
      _ -> change $ \u -> u { errorLabel = err }
    pure []

initialize :: IORef (Maybe Connection) -> IORef (Maybe Player)
  -> ((Ui -> Ui) -> IO ()) -> (ClientCommand -> IO ()) -> IO ()
initialize connectionRef playerRef change sendObserved = do
  let onError err = change $ \u -> u { errorLabel = err }
  B.fetchCatalog $ \result -> case result of
    Left err -> onError err
    Right bytes -> case eitherDecodeStrict' (TE.encodeUtf8 bytes) of
      Left err -> onError $ "Invalid movie catalog: " <> T.pack err
      Right (Catalog entries) -> do
        change $ \u -> u { catalog = entries }
        latestRef <- newIORef Nothing
        let serverTime = do
              room <- readIORef connectionRef
              case room of
                Nothing -> B.now
                Just connection -> serverNow connection
        player <- createPlayer entries sendObserved serverTime
          (\text -> change $ \u -> u { statusLabel = text }) onError
          (\value -> change $ \u -> u { needsEnable = value })
          (\value -> change $ \u -> u { playable = value })
        writeIORef playerRef (Just player)
        connection <- connectRoom $ handleConnection connectionRef latestRef player change
        writeIORef connectionRef (Just connection)
  B.listen "video" "dblclick" $ void $ commandFor playerRef change Fullscreen
  void $ forkIO $ forever $ do
    threadDelay 250000
    updateProgress change

handleConnection :: IORef (Maybe Connection) -> IORef (Maybe RoomState) -> Player
  -> ((Ui -> Ui) -> IO ()) -> ConnectionEvent -> IO ()
handleConnection connectionRef latestRef player change event = case event of
  Connected -> do
    writeIORef latestRef Nothing
    change $ \u -> u { ready = False, connectionLabel = "Synchronizing clock…" }
  Ready -> do
    change $ \u -> u { ready = True, connectionLabel = "Connected · one room" }
    latest <- readIORef latestRef
    case latest of
      Just state -> updatePlayer player state
      Nothing -> pure ()
  Disconnected -> do
    disconnectPlayer player
    change $ \u -> u { ready = False, playable = False, connectionLabel = "Disconnected · retrying", statusLabel = "Playback paused locally. Reconnecting…" }
  ConnectionError err -> change $ \u -> u { errorLabel = err }
  Snapshot incoming -> do
    previous <- readIORef latestRef
    let accepted = acceptSnapshot previous incoming
    if accepted == previous then pure () else do
      writeIORef latestRef accepted
      change $ \u -> u { selected = maybe "" id (mediaId incoming), errorLabel = "" }
      room <- readIORef connectionRef
      case room of
        Nothing -> pure ()
        Just connection -> do
          calibrated <- roomReady connection
          if calibrated then updatePlayer player incoming else pure ()

updateProgress :: ((Ui -> Ui) -> IO ()) -> IO ()
updateProgress change = do
  duration <- B.numberProperty "video" "duration"
  position <- B.numberProperty "video" "currentTime"
  focused <- B.isActive "seek"
  let bound = clampPosition duration duration
  B.setText "seek" "max" (B.toJS $ T.pack $ show bound)
  if focused then pure () else B.setText "seek" "value" (B.toJS $ T.pack $ show position)
  fullscreen <- B.isFullscreen
  change $ \u -> u { timeLabel = formatTime position <> " / " <> formatTime duration, fullscreenActive = fullscreen }

formatTime :: Double -> Text
formatTime seconds
  | not (finite seconds) = "0:00"
  | otherwise = let whole = floor (max 0 seconds) :: Integer
                    suffix = T.pack $ show $ whole `mod` 60
                in T.pack (show $ whole `div` 60) <> ":" <> T.justifyRight 2 '0' suffix
