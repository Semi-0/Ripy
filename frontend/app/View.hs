{-# LANGUAGE OverloadedStrings, FlexibleContexts #-}
module View where

import Control.Monad.IO.Class (liftIO)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Text (Text)
import Reflex.Dom
import qualified Bindings as B
import Protocol (Movie(..))

data Intent = SelectMovie Text Text | Start | Stop | SeekTo Text | SetLocalVolume Text | Enable | Fullscreen
  deriving (Eq, Show)
data Ui = Ui
  { catalog :: [Movie], selected :: Text, connectionLabel :: Text, ready :: Bool
  , playable :: Bool, statusLabel :: Text, errorLabel :: Text, needsEnable :: Bool
  , timeLabel :: Text, fullscreenActive :: Bool }

emptyUi :: Ui
emptyUi = Ui [] "" "Connecting…" False False "Select a movie to begin." "" False "0:00 / 0:00" False

conditional :: Bool -> Map Text Text -> Map Text Text
conditional True attributes = attributes
conditional False _ = Map.empty

movieView :: MonadWidget t m => Dynamic t Ui -> m (Event t [Intent])
movieView ui = elAttr "main" ("data-reflex-ready" =: "true") $ do
  el "header" $ do
    elClass "p" "eyebrow" $ text "PRIVATE SCREENING / SHARED ROOM"
    el "h1" $ do
      el "span" $ text ">"
      text " cloud cinema"
      elClass "span" "cursor" $ text "_"
    elClass "p" "intro" $ text "Choose a movie. Watch together."
  chosen <- elClass "section" "toolbar" $ do
    elAttr "label" ("for" =: "movies") $ text "movie /"
    options <- holdUniqDyn $ (\u -> Map.fromList $ ("", "Choose a movie…") : map (\m -> (movieId m, movieTitle m)) (catalog u)) <$> ui
    selection <- holdUniqDyn $ selected <$> ui
    let disabled u
          | not (ready u) || null (catalog u) = Just ""
          | otherwise = Nothing
        config = def
          & initialAttributes .~ (("id" =: "movies") <> ("disabled" =: ""))
          & modifyAttributes .~ ((\u -> "disabled" =: disabled u) <$> updated ui)
          & selectElementConfig_setValue .~ updated selection
    (selector, _) <- selectElement config $ dyn_ $ ffor options $ \entries ->
      mapM_ (\(ident, title) -> elAttr "option" ("value" =: ident) $ text title) (Map.toList entries)
    elAttr "p" (("id" =: "connection") <> ("role" =: "status")) $ dynText $ connectionLabel <$> ui
    pure $ attachPromptlyDynWith (\previous requested -> [SelectMovie previous requested]) selection $ _selectElement_change selector
  elDynAttr "p" ((\u -> ("id" =: "empty") <> conditional (not $ null $ catalog u) ("hidden" =: "")) <$> ui) $
    text "No movies yet. Add an MP4 to media/, restart the server, and refresh."
  actions <- elAttr "section" (("id" =: "player") <> ("aria-label" =: "Movie player and controls")) $ do
    full <- elClass "div" "player-bar" $ do
      el "span" $ text "SCREEN / 01"
      let attributes u = Map.fromList [("id", "fullscreen"), ("aria-pressed", pressed $ fullscreenActive u)]
          pressed True = "true"
          pressed False = "false"
          label True = "[ exit fullscreen ]"
          label False = "[ fullscreen ]"
      (button, _) <- elDynAttr' "button" (attributes <$> ui) $ dynText $ label . fullscreenActive <$> ui
      pure $ [Fullscreen] <$ domEvent Click button
    elClass "section" "screen" $ do
      elAttr "video" (Map.fromList [("id","video"),("playsinline",""),("preload","auto"),("aria-label","Shared movie")]) blank
      elClass "div" "screen-caption" $ text "[ waiting for a movie ]"
    shared <- controls ui
    (enable, _) <- elDynAttr' "button" ((\u -> ("id" =: "enable") <> conditional (not $ needsEnable u) ("hidden" =: "")) <$> ui) $ text "Enable playback"
    elAttr "p" (("id" =: "status") <> ("role" =: "status")) $ dynText $ statusLabel <$> ui
    elDynAttr "p" ((\u -> Map.fromList [("id","error"),("role","alert")] <> conditional (errorLabel u == "") ("hidden" =: "")) <$> ui) $ dynText $ errorLabel <$> ui
    pure $ mergeWith (++) [shared, full, [Enable] <$ domEvent Click enable]
  el "footer" $ text "Play, pause, and seek are shared. Volume is yours. Open this address in another browser window to join."
  pure $ mergeWith (++) [chosen, actions]

controls :: MonadWidget t m => Dynamic t Ui -> m (Event t [Intent])
controls ui = elClass "section" "controls" $ do
  let disabled ident u = ("id" =: ident) <> conditional (not $ playable u) ("disabled" =: "")
  (play, _) <- elDynAttr' "button" (disabled "play" <$> ui) $ text "Play"
  (pause, _) <- elDynAttr' "button" (disabled "pause" <$> ui) $ text "Pause"
  elAttr "label" (("class" =: "seek-label") <> ("for" =: "seek")) $ do
    text "Timeline "
    elAttr "output" ("id" =: "time") $ dynText $ timeLabel <$> ui
  let seekAttrs = Map.fromList
        [("id","seek"),("type","range"),("min","0"),("step","0.1"),("aria-label","Seek movie"),("disabled","")]
      seekDisabled u
        | playable u = Nothing
        | otherwise = Just ""
  seek <- inputElement $ def
    & inputElementConfig_elementConfig . elementConfig_initialAttributes .~ seekAttrs
    & inputElementConfig_elementConfig . elementConfig_modifyAttributes .~ ((\u -> "disabled" =: seekDisabled u) <$> updated ui)
  elAttr "label" (("class" =: "volume-label") <> ("for" =: "volume")) $ text "Your volume"
  volume <- inputElement $ def & inputElementConfig_initialValue .~ "1"
    & inputElementConfig_elementConfig . elementConfig_initialAttributes .~ Map.fromList [("id","volume"),("type","range"),("min","0"),("max","1"),("step","0.05")]
  pure $ mergeWith (++) [[Start] <$ domEvent Click play, [Stop] <$ domEvent Click pause,
    pure . SeekTo <$> _inputElement_input seek, pure . SetLocalVolume <$> _inputElement_input volume]

restoreMovieSelection :: MonadWidget t m => Event t Text -> m ()
restoreMovieSelection = performEvent_ . fmap (liftIO . B.setText "movies" "value" . B.toJS)
