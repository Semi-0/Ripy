{-# LANGUAGE OverloadedStrings #-}
module MediaManagement
  ( MediaAccess(..), TransferState(..), MediaManagementState(..), MediaManagementEvent(..)
  , initialMediaManagementState, mediaManagementAfter
  ) where

import Data.Aeson
import Data.Text (Text)

data MediaAccess = MediaAccess
  { uploadAllowed :: Bool
  , deleteAllowed :: Bool
  , adminEnabled :: Bool
  , maxUploadBytes :: Integer
  } deriving (Eq, Show)

instance FromJSON MediaAccess where
  parseJSON = withObject "MediaAccess" $ \value -> MediaAccess
    <$> value .: "uploadAllowed"
    <*> value .: "deleteAllowed"
    <*> value .: "adminEnabled"
    <*> value .: "maxUploadBytes"

data TransferState
  = TransferIdle
  | Uploading Double
  | TransferFailed Text
  deriving (Eq, Show)

data MediaManagementState = MediaManagementState
  { mediaAccess :: MediaAccess
  , mediaTransfer :: TransferState
  , mediaMessage :: Text
  } deriving (Eq, Show)

data MediaManagementEvent
  = AccessReceived MediaAccess
  | AccessFailed Text
  | UploadStarted
  | UploadAdvanced Double
  | UploadCompleted Text
  | MutationCompleted Text
  | MutationFailed Text
  deriving (Eq, Show)

initialMediaManagementState :: MediaManagementState
initialMediaManagementState = MediaManagementState
  (MediaAccess False False False 0)
  TransferIdle
  ""

mediaManagementAfter :: MediaManagementEvent -> MediaManagementState -> MediaManagementState
mediaManagementAfter event previous = case event of
  AccessReceived access -> previous { mediaAccess = access, mediaMessage = "" }
  AccessFailed message -> previous { mediaMessage = message }
  UploadStarted -> previous { mediaTransfer = Uploading 0, mediaMessage = "" }
  UploadAdvanced progress -> previous
    { mediaTransfer = Uploading $ max 0 $ min 1 progress }
  UploadCompleted filename -> previous
    { mediaTransfer = TransferIdle, mediaMessage = "Uploaded " <> filename <> ". Select it above to watch." }
  MutationCompleted message -> previous
    { mediaTransfer = TransferIdle, mediaMessage = message }
  MutationFailed message -> previous
    { mediaTransfer = TransferFailed message, mediaMessage = message }
