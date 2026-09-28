{-# LANGUAGE OverloadedStrings, FlexibleContexts #-}
module View where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Text (Text)
import Reflex.Dom
import Protocol

data Intent = Choose Text | Start | Stop | SeekChanged | VolumeChanged | Enable | Fullscreen
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
    el "h1" $ text "> cloud cinema_"
    elClass "p" "intro" $ text "Choose a movie. Watch together."
  chosen <- elClass "section" "toolbar" $ do
    elAttr "label" ("for" =: "movies") $ text "movie /"
    options <- holdUniqDyn $ (\u -> Map.fromList $ ("", "Choose a movie…") : map (\m -> (movieId m, movieTitle m)) (catalog u)) <$> ui
    selection <- holdUniqDyn $ selected <$> ui
    let attributes = (\u -> ("id" =: "movies") <> conditional (not (ready u) || null (catalog u)) ("disabled" =: "")) <$> ui
    dropdownWidget <- dropdown "" options $ def
      & dropdownConfig_attributes .~ attributes
      & dropdownConfig_setValue .~ updated selection
    elAttr "p" (("id" =: "connection") <> ("role" =: "status")) $ dynText $ connectionLabel <$> ui
    pure $ (\ident -> [Choose ident]) <$> _dropdown_change dropdownWidget
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
  let seekAttrs u = disabled "seek" u <> Map.fromList [("type","range"),("min","0"),("step","0.1"),("aria-label","Seek movie")]
  (seek, _) <- elDynAttr' "input" (seekAttrs <$> ui) blank
  elAttr "label" (("class" =: "volume-label") <> ("for" =: "volume")) $ text "Your volume"
  (volume, _) <- elAttr' "input" (Map.fromList [("id","volume"),("type","range"),("min","0"),("max","1"),("step","0.05"),("value","1")]) blank
  pure $ mergeWith (++) [[Start] <$ domEvent Click play, [Stop] <$ domEvent Click pause,
    [SeekChanged] <$ domEvent Change seek, [VolumeChanged] <$ domEvent Input volume]
