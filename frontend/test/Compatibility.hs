{-# LANGUAGE OverloadedStrings #-}
module Main where
import Control.Monad (forM_, unless)
import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Lazy.Char8 as BL
import System.Environment (getArgs)
import Protocol

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> do
      bytes <- BL.readFile path
      case eitherDecode bytes :: Either String [ServerMessage] of
        Left err -> fail err
        Right messages -> do
          unless (length messages == 4) $ fail "Expected actual empty/selected/playing/paused snapshots"
          let modes = [mode state | StateSnapshot state <- messages]
          unless (modes == [Empty, Paused, Playing, Paused]) $ fail "Incorrect server mode decoding"
    _ -> fail "Usage: protocol-check SNAPSHOTS_JSON"
  forM_ [SelectMovie "test.mp4", Play, Pause UserPause, Pause Buffering, Pause Ended, Seek 12.5, Ping 1000] $ \command ->
    case encodeCommand command of
      Left err -> fail $ show err
      Right bytes -> BL.putStrLn bytes
