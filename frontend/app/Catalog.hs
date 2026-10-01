{-# LANGUAGE OverloadedStrings #-}
module Catalog (CatalogState(..), catalogNetwork, catalogMovies, catalogErrors) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (eitherDecodeStrict')
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Reflex.Dom
import qualified Bindings as B
import Protocol

data CatalogState = CatalogLoading | CatalogLoaded [Movie] | CatalogFailed Text
  deriving (Eq, Show)

catalogNetwork :: MonadWidget t m => Event t () -> m (Dynamic t CatalogState)
catalogNetwork refreshRequests = do
  (responses, respond) <- newTriggerEvent
  postBuild <- getPostBuild
  let requests = leftmost [() <$ postBuild, refreshRequests]
  performEvent_ $ (liftIO $ B.afterMount $ B.fetchCatalog respond) <$ requests
  holdDyn CatalogLoading $ decodeCatalog <$> responses

decodeCatalog :: Either Text Text -> CatalogState
decodeCatalog = either CatalogFailed $ either (CatalogFailed . ("Invalid movie catalog: " <>) . T.pack) (CatalogLoaded . movies)
  . eitherDecodeStrict' . TE.encodeUtf8

catalogMovies :: CatalogState -> [Movie]
catalogMovies state = case state of
  CatalogLoaded available -> available
  CatalogLoading -> []
  CatalogFailed _ -> []

catalogErrors :: Reflex t => Dynamic t CatalogState -> Event t Text
catalogErrors = fmapMaybe failed . updated
  where
    failed (CatalogFailed message) = Just message
    failed _ = Nothing
