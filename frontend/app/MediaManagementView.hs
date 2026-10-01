{-# LANGUAGE FlexibleContexts, OverloadedStrings #-}
module MediaManagementView
  ( MediaManagementViewModel(..), MediaManagementSignals(..), mediaManagementView
  ) where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Text (Text)
import Reflex.Dom
import View

data MediaManagementViewModel = MediaManagementViewModel
  { uploadButton :: ButtonView
  , uploadProgress :: Maybe Double
  , adminConfigured :: Bool
  , adminUnlocked :: Bool
  , deleteOptions :: [(Text, Text)]
  , managementMessage :: Text
  } deriving (Eq, Show)

data MediaManagementSignals t = MediaManagementSignals
  { uploadPressed :: Event t ()
  , unlockSubmitted :: Event t Text
  , logoutPressed :: Event t ()
  , deletePressed :: Event t Text
  }

mediaManagementView
  :: MonadWidget t m
  => Dynamic t MediaManagementViewModel
  -> m (MediaManagementSignals t)
mediaManagementView model = elAttr "section"
  (("id" =: "media-management") <> ("aria-label" =: "Movie library management")) $ do
    elClass "div" "media-heading" $ text "LIBRARY / MEDIA"
    fileInputView $ Map.fromList
      [("id", "media-file"), ("type", "file"), ("accept", "video/mp4,.mp4")]
    uploaded <- buttonView $ uploadButton <$> model
    progressView "media-upload-progress" $ uploadProgress <$> model
    password <- textInputView $ Map.fromList
      [("id", "media-admin-password"), ("type", "password"), ("autocomplete", "current-password"), ("placeholder", "administrator password")]
    unlocked <- buttonView $ unlockButton <$> model
    let unlockRequest = tagPromptlyDyn password unlocked
    loggedOut <- buttonView $ logoutButton <$> model
    selected <- holdDyn "" =<< choiceView
      (("id" =: "media-delete-choice") <> ("disabled" =: ""))
      (deleteChoice <$> model)
      never
    deleted <- buttonView $ deleteButton <$> model <*> selected
    dynamicTextView "p" (("id" =: "media-message") <> ("role" =: "status")) $
      managementMessage <$> model
    pure MediaManagementSignals
      { uploadPressed = uploaded
      , unlockSubmitted = unlockRequest
      , logoutPressed = loggedOut
      , deletePressed = tagPromptlyDyn selected deleted
      }

unlockButton :: MediaManagementViewModel -> ButtonView
unlockButton model = ButtonView
  (visibleAttributes ("id" =: "media-admin-unlock") $ adminConfigured model && not (adminUnlocked model))
  "Unlock deletion"
  (adminConfigured model && not (adminUnlocked model))

logoutButton :: MediaManagementViewModel -> ButtonView
logoutButton model = ButtonView
  (visibleAttributes ("id" =: "media-admin-logout") $ adminUnlocked model)
  "Lock deletion"
  (adminUnlocked model)

deleteButton :: MediaManagementViewModel -> Text -> ButtonView
deleteButton model selected = ButtonView
  (visibleAttributes ("id" =: "media-delete") $ adminUnlocked model)
  "Delete movie"
  (adminUnlocked model && any ((== selected) . fst) (deleteOptions model))

deleteChoice :: MediaManagementViewModel -> ChoiceView
deleteChoice model = ChoiceView
  { choiceOptions = ("", "Choose movie to delete…") : deleteOptions model
  , choiceEnabled = adminUnlocked model && not (null $ deleteOptions model)
  }
