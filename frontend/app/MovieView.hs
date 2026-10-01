{-# LANGUAGE FlexibleContexts, OverloadedStrings, RecursiveDo #-}
module MovieView
  ( MovieOption(..), MovieViewModel(..), MovieSignals(..)
  , emptyMovieViewModel, movieView
  ) where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Text (Text)
import Reflex.Dom
import Selection
import View

data MovieOption = MovieOption
  { movieOptionId :: Text
  , movieOptionTitle :: Text
  } deriving (Eq, Show)

data MovieViewModel = MovieViewModel
  { movieOptions :: [MovieOption]
  , selectedMovieId :: Text
  , connectionText :: Text
  , controlsReady :: Bool
  , moviePlayable :: Bool
  , statusText :: Text
  , errorText :: Text
  , enableVisible :: Bool
  , timeText :: Text
  , fullscreenActive :: Bool
  } deriving (Eq, Show)

data MovieSignals t = MovieSignals
  { movieSelected :: Event t Text
  , playPressed :: Event t ()
  , pausePressed :: Event t ()
  , seekChanged :: Event t Text
  , volumeChanged :: Event t Text
  , enablePressed :: Event t ()
  , fullscreenPressed :: Event t ()
  }

emptyMovieViewModel :: MovieViewModel
emptyMovieViewModel = MovieViewModel
  [] "" "Connecting…" False False "Select a movie to begin."
  "" False "0:00 / 0:00" False

movieView :: MonadWidget t m => Dynamic t MovieViewModel -> m (MovieSignals t)
movieView model = do
  movieHeader
  selectedEvent <- movieChooser model
  elDynAttr "p" (emptyAttributes <$> model) $
    text "No movies yet. Upload an MP4 in the library panel below."
  (playEvent, pauseEvent, seekEvent, volumeEvent, enableEvent, fullscreenEvent) <-
    playerView model
  pure MovieSignals
    { movieSelected = selectedEvent
    , playPressed = playEvent
    , pausePressed = pauseEvent
    , seekChanged = seekEvent
    , volumeChanged = volumeEvent
    , enablePressed = enableEvent
    , fullscreenPressed = fullscreenEvent
    }

movieHeader :: MonadWidget t m => m ()
movieHeader = el "header" $ do
  elClass "p" "eyebrow" $ text "PRIVATE SCREENING / SHARED ROOM"
  el "h1" $ do
    el "span" $ text ">"
    text " cloud cinema"
    elClass "span" "cursor" $ text "_"

movieChooser :: MonadWidget t m
  => Dynamic t MovieViewModel -> m (Event t Text)
movieChooser model = elClass "section" "toolbar" $ do
  elAttr "label" ("for" =: "movies") $ text "movie /"
  authoritative <- holdUniqDyn $ selectedMovieId <$> model
  rec let selectionUpdates = mergeWith (++)
            [ pure . ConfirmedSelection <$> updated authoritative
            , pure . RequestedSelection <$> requested
            ]
          selectionWrites =
            attachPromptlyDynWithMaybe selectionWriteAfterMany control selectionUpdates
      control <- foldDyn selectionAfterMany emptySelection selectionUpdates
      requested <- choiceView
        (("id" =: "movies") <> ("disabled" =: ""))
        (choiceModel <$> model)
        selectionWrites
  dynamicTextView "p" (("id" =: "connection") <> ("role" =: "status")) $
    connectionText <$> model
  pure $ fmapMaybe nonempty requested

playerView :: MonadWidget t m
  => Dynamic t MovieViewModel
  -> m (Event t (), Event t (), Event t Text, Event t Text, Event t (), Event t ())
playerView model =
  elAttr "section" (("id" =: "player") <> ("aria-label" =: "Movie player and controls")) $ do
    fullscreenEvent <- elClass "div" "player-bar" $ do
      el "span" $ text "SCREEN / 01"
      buttonView $ fullscreenButton <$> model
    elClass "section" "screen" $ do
      emptyElementView "video" $ Map.fromList
        [("id", "video"), ("playsinline", ""), ("preload", "auto"), ("aria-label", "Shared movie")]
      elClass "div" "screen-caption" $ text "[ waiting for a movie ]"
    (playEvent, pauseEvent, seekEvent, volumeEvent) <- movieControls model
    enableEvent <- buttonView $ enableButton <$> model
    dynamicTextView "p" (("id" =: "status") <> ("role" =: "status")) $
      statusText <$> model
    elDynAttr "p" (errorAttributes <$> model) $ dynText $ errorText <$> model
    pure (playEvent, pauseEvent, seekEvent, volumeEvent, enableEvent, fullscreenEvent)

movieControls :: MonadWidget t m
  => Dynamic t MovieViewModel
  -> m (Event t (), Event t (), Event t Text, Event t Text)
movieControls model = elClass "section" "controls" $ do
  playEvent <- buttonView $ controlButton "play" "Play" <$> model
  pauseEvent <- buttonView $ controlButton "pause" "Pause" <$> model
  elAttr "label" (("class" =: "seek-label") <> ("for" =: "seek")) $ do
    text "Timeline "
    dynamicTextView "output" ("id" =: "time") $ timeText <$> model
  seekEvent <- rangeView seekAttributes "" $ RangeView . moviePlayable <$> model
  elAttr "label" (("class" =: "volume-label") <> ("for" =: "volume")) $
    text "Your volume"
  volumeEvent <- rangeView volumeAttributes "1" $ constDyn $ RangeView True
  pure (playEvent, pauseEvent, seekEvent, volumeEvent)

choiceModel :: MovieViewModel -> ChoiceView
choiceModel model = ChoiceView
  { choiceOptions = ("", "Choose a movie…") :
      map (\option -> (movieOptionId option, movieOptionTitle option)) (movieOptions model)
  , choiceEnabled = controlsReady model && not (null $ movieOptions model)
  }

controlButton :: Text -> Text -> MovieViewModel -> ButtonView
controlButton ident label model = ButtonView
  { buttonAttributes = "id" =: ident
  , buttonLabel = label
  , buttonEnabled = moviePlayable model
  }

fullscreenButton :: MovieViewModel -> ButtonView
fullscreenButton model = ButtonView
  { buttonAttributes = Map.fromList
      [("id", "fullscreen"), ("aria-pressed", pressed $ fullscreenActive model)]
  , buttonLabel = case fullscreenActive model of
      True -> "[ exit fullscreen ]"
      False -> "[ fullscreen ]"
  , buttonEnabled = True
  }
  where
    pressed active = case active of
      True -> "true"
      False -> "false"

enableButton :: MovieViewModel -> ButtonView
enableButton model = ButtonView
  { buttonAttributes = visibleAttributes ("id" =: "enable") (enableVisible model)
  , buttonLabel = "Enable playback"
  , buttonEnabled = True
  }

emptyAttributes :: MovieViewModel -> Map Text Text
emptyAttributes model =
  visibleAttributes ("id" =: "empty") (null $ movieOptions model)

errorAttributes :: MovieViewModel -> Map Text Text
errorAttributes model = visibleAttributes
  (Map.fromList [("id", "error"), ("role", "alert")])
  (errorText model /= "")

seekAttributes :: Map AttributeName Text
seekAttributes = Map.fromList
  [ ("id", "seek"), ("type", "range"), ("min", "0"), ("step", "0.1")
  , ("aria-label", "Seek movie"), ("disabled", "")
  ]

volumeAttributes :: Map AttributeName Text
volumeAttributes = Map.fromList
  [ ("id", "volume"), ("type", "range"), ("min", "0"), ("max", "1")
  , ("step", "0.05")
  ]

nonempty :: Text -> Maybe Text
nonempty value = case value == "" of
  True -> Nothing
  False -> Just value
