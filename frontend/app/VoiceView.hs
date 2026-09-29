{-# LANGUAGE FlexibleContexts, OverloadedStrings #-}
module VoiceView
  ( VoiceViewModel(..), VoiceSignals(..), voiceView
  ) where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Text (Text)
import Reflex.Dom
import View

data VoiceViewModel = VoiceViewModel
  { joinButton :: ButtonView
  , leaveButton :: ButtonView
  , muteButton :: ButtonView
  , enableAudioButton :: ButtonView
  , voiceStatusText :: Text
  , voiceErrorText :: Text
  } deriving (Eq, Show)

data VoiceSignals t = VoiceSignals
  { joinPressed :: Event t ()
  , leavePressed :: Event t ()
  , mutePressed :: Event t ()
  , enableAudioPressed :: Event t ()
  }

voiceView :: MonadWidget t m
  => Dynamic t VoiceViewModel -> m (VoiceSignals t)
voiceView model = elAttr "section"
  (("id" =: "voice") <> ("aria-label" =: "Private voice call")) $ do
    elClass "div" "voice-heading" $ do
      el "span" $ text "VOICE / P2P"
      dynamicTextView "span" ("id" =: "voice-status") $
        voiceStatusText <$> model
    elClass "div" "voice-controls" $ do
      joined <- buttonView $ joinButton <$> model
      left <- buttonView $ leaveButton <$> model
      muted <- buttonView $ muteButton <$> model
      enabled <- buttonView $ enableAudioButton <$> model
      emptyElementView "audio" $ Map.fromList
        [ ("id", "voice-audio")
        , ("autoplay", "")
        , ("playsinline", "")
        , ("aria-label", "Friend voice")
        ]
      elDynAttr "p" (errorAttributes <$> model) $
        dynText $ voiceErrorText <$> model
      pure VoiceSignals
        { joinPressed = joined
        , leavePressed = left
        , mutePressed = muted
        , enableAudioPressed = enabled
        }

errorAttributes :: VoiceViewModel -> Map Text Text
errorAttributes model = visibleAttributes
  (Map.fromList [("id", "voice-error"), ("role", "alert")])
  (voiceErrorText model /= "")
