{-# LANGUAGE OverloadedStrings #-}
module Main where
import Control.Monad (unless, forM_)
import Data.Aeson (eitherDecode, decode, Value)
import qualified Data.ByteString.Lazy.Char8 as BL
import Protocol
import Model
import Selection
import VoiceProtocol

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
  let confirmedMovie = selectionAfter (ConfirmedSelection "test.mp4") emptySelection
      pendingAlternate = selectionAfter (RequestedSelection "alternate.mp4") confirmedMovie
      pendingTest = selectionAfter (RequestedSelection "test.mp4") pendingAlternate
      staleAlternate = selectionAfter (ConfirmedSelection "alternate.mp4") pendingTest
      confirmedTest = selectionAfter (ConfirmedSelection "test.mp4") staleAlternate
  check "empty selection restores displayed value" $
    selectionAfter (RequestedSelection "") confirmedMovie == confirmedMovie
  check "stale acknowledgement preserves latest selection" $
    displayedSelection staleAlternate == "test.mp4" && pendingSelection staleAlternate == Just "test.mp4"
  check "matching acknowledgement clears pending selection" $
    confirmedTest == SelectionControl "test.mp4" "test.mp4" Nothing
  check "local selection needs no redundant DOM write" $
    selectionWriteAfter confirmedMovie (RequestedSelection "alternate.mp4") == Nothing
  check "placeholder restores current display" $
    selectionWriteAfter confirmedMovie (RequestedSelection "") == Just "test.mp4"
  check "stale acknowledgement writes latest pending display" $
    selectionWriteAfter pendingTest (ConfirmedSelection "alternate.mp4") == Just "test.mp4"
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
  forM_
    [ (VoiceOffer "offer-sdp", "{\"sdp\":\"offer-sdp\",\"type\":\"offer\"}")
    , (VoiceAnswer "answer-sdp", "{\"sdp\":\"answer-sdp\",\"type\":\"answer\"}")
    , (VoiceIce $ IceCandidate "candidate:1" (Just "0") (Just 0),
        "{\"candidate\":\"candidate:1\",\"sdpMLineIndex\":0,\"sdpMid\":\"0\",\"type\":\"ice\"}")
    , (VoiceLeave, "{\"type\":\"leave\"}")
    ] $ \(signal, expected) -> case encodeVoiceSignal signal of
      Left _ -> fail "valid voice signal rejected"
      Right bytes -> check "voice wire compatibility" $ (decode bytes :: Maybe Value) == decode expected
  forM_ [VoiceOffer "", VoiceIce $ IceCandidate "" Nothing Nothing] $ \signal ->
    case encodeVoiceSignal signal of
      Left _ -> pure ()
      Right _ -> fail "invalid voice signal encoded"
  check "decode waiting" $
    eitherDecode "{\"type\":\"waiting\"}" == Right VoiceWaiting
  check "decode peer role" $
    eitherDecode "{\"type\":\"peer-ready\",\"role\":\"offerer\"}" == Right (VoicePeerReady Offerer)
  check "decode ICE response" $
    eitherDecode "{\"iceServers\":[{\"urls\":[\"stun:voice.example\"]}],\"expiresAt\":null}" ==
      Right (VoiceIceResponse [IceServer ["stun:voice.example"] Nothing Nothing] Nothing)
  forM_ ["{\"type\":\"peer-ready\",\"role\":\"unknown\"}",
    "{\"type\":\"ice\",\"candidate\":\"\",\"sdpMid\":null,\"sdpMLineIndex\":0}"] $ \bytes ->
      case eitherDecode bytes :: Either String VoiceServerMessage of
        Left _ -> pure ()
        Right _ -> fail "invalid voice server message accepted"
  putStrLn "PASS Haskell movie and voice JSON, timeline, clocks, epochs, stale snapshots, selection control and bounds"
