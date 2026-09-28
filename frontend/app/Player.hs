{-# LANGUAGE OverloadedStrings #-}
module Player
  ( VideoInputs(..), PlayerState(..), PlayerNetwork(..), videoController ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO)
import Data.IORef
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import Reflex.Dom
import Bindings
import Model
import Protocol

data Player = Player
  { updatePlayer :: RoomState -> IO (), disconnectPlayer :: IO (), enablePlayback :: IO () }
data Playback = Playback
  { latest :: Maybe RoomState, connected :: Bool, loaded :: Maybe Text
  , version :: Int, applying :: Bool, reported :: Bool }

data VideoInputs t = VideoInputs
  { videoStates :: Event t RoomState
  , videoDisconnects :: Event t ()
  , videoEnableRequests :: Event t ()
  , videoFullscreenRequests :: Event t ()
  , videoVolumes :: Event t Double
  }

data PlayerEvent
  = PlayerStatus Text
  | PlayerError Text
  | ClearPlayerError
  | PlayerEnable Bool
  | PlayerPlayable Bool
  | PlayerProgress Double Double Bool

data PlayerState = PlayerState
  { playerStatus :: Text
  , playerError :: Text
  , playerNeedsEnable :: Bool
  , playerPlayable :: Bool
  , playerDuration :: Double
  , playerTimeLabel :: Text
  , playerFullscreen :: Bool
  } deriving (Eq, Show)

data PlayerNetwork t = PlayerNetwork
  { playerState :: Dynamic t PlayerState
  , playerMediaCommands :: Event t [ClientCommand]
  }

initialPlayerState :: PlayerState
initialPlayerState = PlayerState "Select a movie to begin." "" False False 0 "0:00 / 0:00" False

-- Browser callbacks enter as events; only browser-resource handles and
-- cancellation generations remain mutable inside this adapter.
videoController :: MonadWidget t m
  => Dynamic t [Movie] -> IO Double -> VideoInputs t -> m (PlayerNetwork t)
videoController catalog serverTime inputs = do
  (events, emit) <- newTriggerEvent
  (mediaCommands, emitMediaCommand) <- newTriggerEvent
  playerRef <- liftIO $ newIORef Nothing
  catalogRef <- liftIO $ newIORef []
  performEvent_ $ ffor (updated catalog) $ liftIO . writeIORef catalogRef
  getPostBuild >>= performEvent_ . fmap (\() -> do
    initialCatalog <- sample $ current catalog
    liftIO $ do
      writeIORef catalogRef initialCatalog
      afterMount $ do
        player <- createPlayer (readIORef catalogRef) (emitMediaCommand . pure) serverTime
          (emit . PlayerStatus) (emit . PlayerError) (emit . PlayerEnable) (emit . PlayerPlayable)
        writeIORef playerRef $ Just player
        listen "video" "dblclick" $ toggleFullscreen emit
        void $ forkIO $ forever $ threadDelay 250000 >> emitProgress emit)
  performEvent_ $ ffor (videoStates inputs) $ \snapshot -> liftIO $ do
    emit ClearPlayerError
    withPlayer playerRef (`updatePlayer` snapshot)
  performEvent_ $ ffor (videoDisconnects inputs) $ const $ liftIO $ withPlayer playerRef disconnectPlayer
  performEvent_ $ ffor (videoEnableRequests inputs) $ const $ liftIO $ withPlayer playerRef enablePlayback
  performEvent_ $ ffor (videoFullscreenRequests inputs) $ const $ liftIO $ toggleFullscreen emit
  performEvent_ $ ffor (videoVolumes inputs) $ liftIO . setNumber "video" "volume"
  state <- foldDyn playerStateAfter initialPlayerState events
  pure $ PlayerNetwork state mediaCommands

withPlayer :: IORef (Maybe Player) -> (Player -> IO ()) -> IO ()
withPlayer ref action = readIORef ref >>= maybe (pure ()) action

toggleFullscreen :: (PlayerEvent -> IO ()) -> IO ()
toggleFullscreen emit = fullscreen $ \result -> if result == "" then pure () else emit $ PlayerError result

emitProgress :: (PlayerEvent -> IO ()) -> IO ()
emitProgress emit = do
  duration <- numberProperty "video" "duration"
  position <- numberProperty "video" "currentTime"
  focused <- isActive "seek"
  let bound = clampPosition duration duration
  setText "seek" "max" $ toJS $ T.pack $ show bound
  if focused then pure () else setText "seek" "value" $ toJS $ T.pack $ show position
  PlayerProgress position duration <$> isFullscreen >>= emit

playerStateAfter :: PlayerEvent -> PlayerState -> PlayerState
playerStateAfter event state = case event of
  PlayerStatus message -> state { playerStatus = message }
  PlayerError message -> state { playerError = message }
  ClearPlayerError -> state { playerError = "" }
  PlayerEnable value -> state { playerNeedsEnable = value }
  PlayerPlayable value -> state { playerPlayable = value }
  PlayerProgress position duration fullscreenActive -> state
    { playerDuration = clampPosition duration duration
    , playerTimeLabel = formatTime position <> " / " <> formatTime duration
    , playerFullscreen = fullscreenActive
    }

formatTime :: Double -> Text
formatTime seconds
  | not (finite seconds) = "0:00"
  | otherwise = let whole = floor (max 0 seconds) :: Integer
                    suffix = T.pack $ show $ whole `mod` 60
                in T.pack (show $ whole `div` 60) <> ":" <> T.justifyRight 2 '0' suffix

createPlayer :: IO [Movie] -> (ClientCommand -> IO ()) -> IO Double
  -> (Text -> IO ()) -> (Text -> IO ()) -> (Bool -> IO ()) -> (Bool -> IO ()) -> IO Player
createPlayer readCatalog send serverTime status onError enabled playable = do
  ref <- newIORef $ Playback Nothing False Nothing 0 False False
  let current token action = do
        state <- readIORef ref
        if connected state && version state == token then action else pure ()
      target state = do
        time <- serverTime
        duration <- numberProperty "video" "duration"
        pure $ clampPosition (positionAt state time) duration
      refresh = do
        state <- readIORef ref
        duration <- numberProperty "video" "duration"
        playable $ connected state && finite duration && loaded state /= Nothing && not (applying state)
      report reason = do
        state <- readIORef ref
        case latest state of
          Just snapshot | connected state && mode snapshot == Playing && not (reported state) -> do
            modifyIORef' ref $ \s -> s { reported = True }
            send (Pause reason)
          _ -> pure ()
      play token = do
        pending <- newIORef True
        void $ forkIO $ do
          threadDelay 2000000
          current token $ do
            waiting <- readIORef pending
            ready <- numberProperty "video" "readyState"
            if waiting && ready < 3 then report Buffering else pure ()
        playVideo $ \err -> do
          writeIORef pending False
          current token $ do
            modifyIORef' ref $ \s -> s { applying = False }
            if err == "" then enabled False
            else if "NotAllowedError:" `T.isPrefixOf` err then do
              enabled True
              status "Your browser needs permission. Click Enable playback."
            else onError err
            refresh
      finish snapshot token = current token $ do
        position <- target snapshot
        setNumber "video" "currentTime" position
        case mode snapshot of
          Playing -> status "Watching together." >> play token
          Paused -> do
            pauseVideo
            status $ pauseMessage $ pauseReason snapshot
            modifyIORef' ref $ \s -> s { applying = False }
            refresh
          Empty -> onError "Unexpected empty movie update."
      waitMetadata snapshot token deadline = current token $ do
        ready <- numberProperty "video" "readyState"
        failed <- videoFailed
        time <- now
        if failed then failLoad "Cannot load this movie. Check video/audio compatibility."
        else if ready >= 1 then finish snapshot token
        else if time >= deadline then failLoad "Movie loading timed out. Try selecting it again."
        else threadDelay 20000 >> waitMetadata snapshot token deadline
      failLoad message = do
        modifyIORef' ref $ \s -> s { applying = False }
        onError message
        playable False
      apply snapshot token = current token $ case mediaId snapshot of
        Nothing -> do
          clearVideo
          loadVideo
          modifyIORef' ref $ \s -> s { loaded = Nothing, applying = False }
          status "Select a movie to begin."
          refresh
        Just ident -> do
          catalog <- readCatalog
          case find ((== ident) . movieId) catalog of
            Nothing -> failLoad "Movie catalog changed. Refresh this page."
            Just movie -> do
              state <- readIORef ref
              failed <- videoFailed
              if loaded state /= Just ident || failed then do
                modifyIORef' ref $ \s -> s { loaded = Just ident }
                setText "video" "src" (toJS $ movieUrl movie)
                loadVideo
              else pure ()
              time <- now
              waitMetadata snapshot token (time + 15000)
      update snapshot = do
        previous <- readIORef ref
        let token = version previous + 1
        writeIORef ref $ previous { latest = Just snapshot, connected = True, version = token, applying = True, reported = False }
        enabled False
        playable False
        pauseVideo
        -- Superseded loads exit at the next generation check without touching the player.
        void $ forkIO $ apply snapshot token
      disconnect = do
        modifyIORef' ref $ \s -> s { connected = False, version = version s + 1, applying = False }
        pauseVideo
        enabled False
        playable False
      enable = do
        state <- readIORef ref
        case latest state of
          Just snapshot | connected state && mode snapshot == Playing -> do
            position <- target snapshot
            setNumber "video" "currentTime" position
            play (version state)
          _ -> enabled False
  listen "video" "waiting" $ do
    state <- readIORef ref
    seeking <- boolProperty "video" "seeking"
    if not (applying state) && not seeking then report Buffering else pure ()
  listen "video" "ended" $ report Ended
  listen "video" "error" $ do
    state <- readIORef ref
    if loaded state /= Nothing then onError "Movie playback failed. Check video/audio compatibility." >> report Buffering else pure ()
  void $ forkIO $ forever $ do
    threadDelay 1000000
    state <- readIORef ref
    paused <- boolProperty "video" "paused"
    seeking <- boolProperty "video" "seeking"
    ready <- numberProperty "video" "readyState"
    case latest state of
      Just snapshot | connected state && mode snapshot == Playing && not (applying state) && not paused && not seeking && ready >= 2 -> do
        position <- numberProperty "video" "currentTime"
        expected <- target snapshot
        if abs (position - expected) > 0.5 then setNumber "video" "currentTime" expected else pure ()
      _ -> pure ()
  pure $ Player update disconnect enable
