{-# LANGUAGE OverloadedStrings #-}
module Player (Player(..), createPlayer) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forever, void)
import Data.IORef
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import Bindings
import Model
import Protocol

data Player = Player
  { updatePlayer :: RoomState -> IO (), disconnectPlayer :: IO (), enablePlayback :: IO () }
data Playback = Playback
  { latest :: Maybe RoomState, connected :: Bool, loaded :: Maybe Text
  , version :: Int, applying :: Bool, reported :: Bool }

createPlayer :: [Movie] -> (ClientCommand -> IO ()) -> IO Double
  -> (Text -> IO ()) -> (Text -> IO ()) -> (Bool -> IO ()) -> (Bool -> IO ()) -> IO Player
createPlayer catalog send serverTime status onError enabled playable = do
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
        Just ident -> case find ((== ident) . movieId) catalog of
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
