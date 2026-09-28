{-# LANGUAGE OverloadedStrings #-}
module Model where

import Data.List (minimumBy)
import Data.Ord (comparing)
import Data.Text (Text)
import Protocol

data ClockSample = ClockSample { roundTrip :: Double, offset :: Double } deriving (Eq, Show)

acceptSnapshot :: Maybe RoomState -> RoomState -> Maybe RoomState
acceptSnapshot Nothing incoming = Just incoming
acceptSnapshot previous@(Just current) incoming
  | epoch current /= epoch incoming = Just incoming
  | revision incoming > revision current = Just incoming
  | otherwise = previous

positionAt :: RoomState -> Double -> Double
positionAt state now = case mode state of
  Empty -> 0
  Paused -> positionSeconds state
  Playing -> positionSeconds state + max 0 (now - anchorServerTimeMs state) / 1000

clampPosition :: Double -> Double -> Double
clampPosition position duration
  | finite position && finite duration && duration >= 0 = max 0 (min duration position)
  | otherwise = 0

clockSample :: Double -> Double -> Double -> Maybe ClockSample
clockSample sent received server
  | all finite [sent, received, server] && received >= sent =
      Just $ ClockSample (received - sent) (server - (sent + received) / 2)
  | otherwise = Nothing

bestClockSample :: [ClockSample] -> Maybe ClockSample
bestClockSample [] = Nothing
bestClockSample samples = Just $ minimumBy (comparing roundTrip) samples

pauseMessage :: Maybe Text -> Text
pauseMessage reason = case reason of
  Just "buffering" -> "A viewer is buffering. Wait until ready, then press Play."
  Just "ended" -> "Movie ended."
  Just "selected" -> "Movie ready. Press Play when you are both ready."
  Just "user" -> "Paused for everyone."
  _ -> "Paused."
