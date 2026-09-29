{-# LANGUAGE FlexibleContexts, OverloadedStrings #-}
module View
  ( ButtonView(..), ChoiceView(..), RangeView(..)
  , buttonView, choiceView, rangeView
  , dynamicTextView, emptyElementView
  , conditional, visibleAttributes
  ) where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Text (Text)
import Reflex.Dom

data ButtonView = ButtonView
  { buttonAttributes :: Map Text Text
  , buttonLabel :: Text
  , buttonEnabled :: Bool
  } deriving (Eq, Show)

data ChoiceView = ChoiceView
  { choiceOptions :: [(Text, Text)]
  , choiceEnabled :: Bool
  } deriving (Eq, Show)

data RangeView = RangeView
  { rangeEnabled :: Bool
  } deriving (Eq, Show)

conditional :: Bool -> Map Text Text -> Map Text Text
conditional condition attributes = case condition of
  True -> attributes
  False -> Map.empty

visibleAttributes :: Map Text Text -> Bool -> Map Text Text
visibleAttributes attributes visible =
  attributes <> conditional (not visible) ("hidden" =: "")

buttonView :: MonadWidget t m => Dynamic t ButtonView -> m (Event t ())
buttonView model = do
  stable <- holdUniqDyn model
  (button, _) <- elDynAttr' "button" (attributes <$> stable) $
    dynText $ buttonLabel <$> stable
  pure $ () <$ domEvent Click button
  where
    attributes view = buttonAttributes view <>
      conditional (not $ buttonEnabled view) ("disabled" =: "")

choiceView :: MonadWidget t m
  => Map AttributeName Text
  -> Dynamic t ChoiceView
  -> Event t Text
  -> m (Event t Text)
choiceView initial model writes = do
  -- A server acknowledgement may arrive in the same browser turn as a newer
  -- user choice. Defer programmatic restoration so the user event is observed.
  deferredWrites <- delay 0.02 writes
  options <- holdUniqDyn $ choiceOptions <$> model
  enabled <- holdUniqDyn $ choiceEnabled <$> model
  let config = def
        & initialAttributes .~ initial
        & modifyAttributes .~ (disabledChange <$> updated enabled)
        & selectElementConfig_setValue .~ deferredWrites
  (selector, _) <- selectElement config $ dyn_ $ ffor options $
    mapM_ choiceOption
  pure $ _selectElement_change selector
  where
    choiceOption (ident, label) =
      elAttr "option" ("value" =: ident) $ text label

rangeView :: MonadWidget t m
  => Map AttributeName Text
  -> Text
  -> Dynamic t RangeView
  -> m (Event t Text)
rangeView initial initialValue model = do
  enabled <- holdUniqDyn $ rangeEnabled <$> model
  input <- inputElement $ def
    & inputElementConfig_initialValue .~ initialValue
    & inputElementConfig_elementConfig . elementConfig_initialAttributes .~ initial
    & inputElementConfig_elementConfig . elementConfig_modifyAttributes
      .~ (disabledChange <$> updated enabled)
  pure $ _inputElement_input input

dynamicTextView :: MonadWidget t m
  => Text -> Map Text Text -> Dynamic t Text -> m ()
dynamicTextView element attributes value = do
  stable <- holdUniqDyn value
  elAttr element attributes $ dynText stable

emptyElementView :: MonadWidget t m
  => Text -> Map Text Text -> m ()
emptyElementView element attributes = elAttr element attributes blank

disabledChange :: Bool -> Map AttributeName (Maybe Text)
disabledChange enabled = Map.singleton "disabled" $ case enabled of
  True -> Nothing
  False -> Just ""
