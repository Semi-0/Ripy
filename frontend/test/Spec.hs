{-# LANGUAGE OverloadedStrings #-}
module Main where
import Control.Monad (unless, forM_)
import Data.Aeson (eitherDecode, decode, Value)
import qualified Data.ByteString.Lazy.Char8 as BL
import Protocol
import Model

check :: String -> Bool -> IO ()
check label result = unless result $ fail label

main :: IO ()
main = do
  let empty = RoomState "a" 0 Nothing Empty 0 1000 Nothing
      playing = RoomState "a" 2 (Just "453.MP4") Playing 12 1000 Nothing
      paused = playing { mode = Paused }
  check "empty timeline" $ positionAt empty 5000 == 0
  check "playing timeline" $ positionAt playing 4000 == 15
  check "negative elapsed clamped" $ positionAt playing 0 == 12
  check "paused timeline" $ positionAt paused 4000 == 12
  check "late join" $ acceptSnapshot Nothing playing == Just playing
  check "duplicate ignored" $ acceptSnapshot (Just playing) playing == Just playing
  check "stale ignored" $ acceptSnapshot (Just playing) empty == Just playing
  check "epoch reset" $ acceptSnapshot (Just playing) (empty { epoch = "b" }) == Just (empty { epoch = "b" })
  check "newer accepted" $ acceptSnapshot (Just empty) playing == Just playing
  check "clamp media duration" $ clampPosition 300 30 == 30 && clampPosition (-2) 30 == 0
  check "invalid duration" $ clampPosition 3 (0/0) == 0
  let samples = [ClockSample 80 50, ClockSample 10 100, ClockSample 90 200, ClockSample 12 90, ClockSample 100 20]
  check "five samples choose lowest RTT" $ bestClockSample samples == Just (ClockSample 10 100)
  check "midpoint offset" $ clockSample 1000 1100 2050 == Just (ClockSample 100 1000)
  check "invalid samples" $ clockSample 1000 900 2050 == Nothing && bestClockSample [] == Nothing
  forM_ [(Play,"{\"type\":\"play\"}"),(Pause UserPause,"{\"type\":\"pause\",\"reason\":\"user\"}"),
         (Pause Buffering,"{\"type\":\"pause\",\"reason\":\"buffering\"}"),(Pause Ended,"{\"type\":\"pause\",\"reason\":\"ended\"}"),
         (Seek 12,"{\"type\":\"seek\",\"positionSeconds\":12}"),(Ping 1000,"{\"type\":\"ping\",\"clientSentAtMs\":1000}"),
         (SelectMovie "453.MP4","{\"type\":\"select\",\"mediaId\":\"453.MP4\"}")] $ \(command, expected) ->
    case encodeCommand command of
      Left _ -> fail "valid command rejected"
      Right bytes -> check "wire compatibility" $ (decode bytes :: Maybe Value) == decode expected
  forM_ [Seek (-1), Seek (0/0), Ping (1/0)] $ \command -> case encodeCommand command of
    Left _ -> pure ()
    Right _ -> fail "invalid command encoded"
  forM_ ["{}", "{\"type\":\"pong\",\"clientSentAtMs\":1e999,\"serverTimeMs\":2}",
    "{\"type\":\"state\",\"epoch\":\"a\",\"revision\":0,\"mediaId\":null,\"mode\":\"unknown\",\"positionSeconds\":0,\"anchorServerTimeMs\":0,\"pauseReason\":null}"] $ \bytes ->
      case eitherDecode bytes :: Either String ServerMessage of
        Left _ -> pure ()
        Right _ -> fail "invalid server message accepted"
  putStrLn "PASS Haskell JSON, timeline, clocks, epochs, stale snapshots and bounds"
