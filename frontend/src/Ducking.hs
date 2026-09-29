module Ducking
  ( DuckingPolicy(..)
  , VoiceActivity(..)
  , defaultDuckingPolicy
  , resetVoiceActivity
  , observeRemoteLevel
  , effectiveMovieVolume
  ) where

data DuckingPolicy = DuckingPolicy
  { speakingThreshold :: Double
  , attackSamples :: Int
  , releaseSamples :: Int
  , duckingFactor :: Double
  } deriving (Eq, Show)

data VoiceActivity = VoiceActivity
  { activeSampleCount :: Int
  , quietSampleCount :: Int
  , activitySpeaking :: Bool
  } deriving (Eq, Show)

defaultDuckingPolicy :: DuckingPolicy
defaultDuckingPolicy = DuckingPolicy 0.02 2 8 0.25

resetVoiceActivity :: VoiceActivity
resetVoiceActivity = VoiceActivity 0 0 False

observeRemoteLevel
  :: DuckingPolicy -> Double -> VoiceActivity -> VoiceActivity
observeRemoteLevel policy level previous
  | validLevel policy level =
      let active = min (boundedAttack policy) $ activeSampleCount previous + 1
      in VoiceActivity active 0 $
        activitySpeaking previous || active >= boundedAttack policy
  | otherwise =
      let quiet = min (boundedRelease policy) $ quietSampleCount previous + 1
      in VoiceActivity 0 quiet $
        activitySpeaking previous && quiet < boundedRelease policy

effectiveMovieVolume :: DuckingPolicy -> Double -> Bool -> Double
effectiveMovieVolume policy base speaking = bounded base * factor
  where
    factor = case speaking of
      True -> bounded $ duckingFactor policy
      False -> 1

validLevel :: DuckingPolicy -> Double -> Bool
validLevel policy level = finite level && level >= max 0 (speakingThreshold policy)

boundedAttack :: DuckingPolicy -> Int
boundedAttack = max 1 . attackSamples

boundedRelease :: DuckingPolicy -> Int
boundedRelease = max 1 . releaseSamples

bounded :: Double -> Double
bounded value = case finite value of
  True -> max 0 $ min 1 value
  False -> 0

finite :: Double -> Bool
finite value = not (isNaN value || isInfinite value)
