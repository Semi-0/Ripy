{-# LANGUAGE OverloadedStrings #-}
module Selection where

import Data.Text (Text)
import qualified Data.Text as T

data SelectionControl = SelectionControl
  { confirmedSelection :: Text
  , displayedSelection :: Text
  , pendingSelection :: Maybe Text
  } deriving (Eq, Show)

data SelectionUpdate = ConfirmedSelection Text | RequestedSelection Text
  deriving (Eq, Show)

emptySelection :: SelectionControl
emptySelection = SelectionControl "" "" Nothing

selectionAfter :: SelectionUpdate -> SelectionControl -> SelectionControl
selectionAfter update state = case update of
  RequestedSelection requested -> case T.null requested of
    True -> state
    False -> state { displayedSelection = requested, pendingSelection = Just requested }
  ConfirmedSelection confirmed -> case pendingSelection state of
    Nothing -> SelectionControl confirmed confirmed Nothing
    Just pending -> case pending == confirmed of
      True -> SelectionControl confirmed confirmed Nothing
      False -> state { confirmedSelection = confirmed }
