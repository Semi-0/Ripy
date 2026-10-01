{-# LANGUAGE FlexibleContexts, OverloadedStrings #-}
module MediaTransfer
  ( MediaManagementInputs(..), MediaManagementNetwork(..), mediaManagementController
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (eitherDecodeStrict')
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Reflex.Dom
import qualified Bindings as B
import MediaManagement
import qualified MediaBindings as MB

data MediaManagementInputs t = MediaManagementInputs
  { uploadRequests :: Event t ()
  , adminUnlockRequests :: Event t Text
  , adminLogoutRequests :: Event t ()
  , adminDeleteRequests :: Event t Text
  }

data MediaManagementNetwork t = MediaManagementNetwork
  { mediaManagementState :: Dynamic t MediaManagementState
  , mediaCatalogChanged :: Event t ()
  }

data MediaIntent = UploadMedia | UnlockAdmin Text | LogoutAdmin | DeleteMovie Text

mediaManagementController
  :: MonadWidget t m
  => m (MediaManagementNetwork t, MediaManagementInputs t -> m ())
mediaManagementController = do
  (events, emit) <- newTriggerEvent
  (catalogChanges, catalogChanged) <- newTriggerEvent
  state <- foldDyn mediaManagementAfter initialMediaManagementState events
  getPostBuild >>= performEvent_ . fmap (const $ liftIO $ B.afterMount $ do
    refreshAccess emit
    MB.openMediaEvents (catalogChanged () >> refreshAccess emit) (emit . AccessFailed))
  let control inputs = performEvent_ $ fmap (liftIO . mapM_ (applyIntent emit catalogChanged)) $
        mergeWith (++)
          [ [UploadMedia] <$ uploadRequests inputs
          , pure . UnlockAdmin <$> adminUnlockRequests inputs
          , [LogoutAdmin] <$ adminLogoutRequests inputs
          , pure . DeleteMovie <$> adminDeleteRequests inputs
          ]
  pure (MediaManagementNetwork state catalogChanges, control)

applyIntent
  :: (MediaManagementEvent -> IO ()) -> (() -> IO ()) -> MediaIntent -> IO ()
applyIntent emit catalogChanged intent = case intent of
  UploadMedia -> do
    emit UploadStarted
    MB.uploadSelectedMedia (emit . UploadAdvanced) $ either
      (emit . MutationFailed)
      (\filename -> emit (UploadCompleted filename) >> catalogChanged ())
  UnlockAdmin password -> MB.createAdminSession password $ either
    (emit . MutationFailed)
    (const $ refreshAccess emit)
  LogoutAdmin -> MB.deleteAdminSession $ either
    (emit . MutationFailed)
    (const $ refreshAccess emit)
  DeleteMovie filename -> MB.deleteMedia filename $ either
    (emit . MutationFailed)
    (const $ emit (MutationCompleted $ "Deleted " <> filename <> ".") >> catalogChanged ())

refreshAccess :: (MediaManagementEvent -> IO ()) -> IO ()
refreshAccess emit = MB.fetchMediaAccess $ either
  (emit . AccessFailed)
  (either (emit . AccessFailed . ("Invalid media access response: " <>) . T.pack)
    (emit . AccessReceived) . eitherDecodeStrict' . TE.encodeUtf8)
