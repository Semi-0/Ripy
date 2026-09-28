{-# LANGUAGE OverloadedStrings #-}
module Protocol where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Data.String (fromString)

data PauseCause = UserPause | Buffering | Ended deriving (Eq, Show)
data ClientCommand = SelectMovie Text | Play | Pause PauseCause | Seek Double | Ping Double
  deriving (Eq, Show)
data PlaybackMode = Empty | Paused | Playing deriving (Eq, Show)
data RoomState = RoomState
  { epoch :: Text, revision :: Integer, mediaId :: Maybe Text, mode :: PlaybackMode
  , positionSeconds :: Double, anchorServerTimeMs :: Double, pauseReason :: Maybe Text
  } deriving (Eq, Show)
data ServerMessage = StateSnapshot RoomState | Pong Double Double | ServerError Text Text
  deriving (Eq, Show)
data Movie = Movie { movieId :: Text, movieTitle :: Text, movieUrl :: Text } deriving (Eq, Show)
newtype Catalog = Catalog { movies :: [Movie] } deriving (Eq, Show)

finite :: Double -> Bool
finite x = not (isNaN x || isInfinite x)

instance ToJSON ClientCommand where
  toJSON command = case command of
    SelectMovie ident -> object ["type" .= String "select", "mediaId" .= ident]
    Play -> object ["type" .= String "play"]
    Pause cause -> object ["type" .= String "pause", "reason" .= reason cause]
    Seek seconds -> object ["type" .= String "seek", "positionSeconds" .= seconds]
    Ping sent -> object ["type" .= String "ping", "clientSentAtMs" .= sent]
    where
      reason UserPause = String "user"
      reason Buffering = String "buffering"
      reason Ended = String "ended"

-- Reject before encoding: Aeson must never turn non-finite command numbers into null.
encodeCommand :: ClientCommand -> Either Text BL.ByteString
encodeCommand command = case command of
  Seek n | not (finite n) || n < 0 -> Left "Invalid seek position."
  Ping n | not (finite n) -> Left "Invalid clock sample."
  SelectMovie "" -> Left "Select a movie first."
  _ -> Right (encode command)

number :: Object -> Text -> Parser Double
number obj key = do
  value <- obj .: fromString (T.unpack key)
  unless (finite value) $ fail "Non-finite numeric field"
  pure value

instance FromJSON PlaybackMode where
  parseJSON = withText "PlaybackMode" $ \value -> case value of
    "empty" -> pure Empty
    "paused" -> pure Paused
    "playing" -> pure Playing
    _ -> fail "Unknown playback mode"

instance FromJSON RoomState where
  parseJSON = withObject "RoomState" $ \obj -> do
    e <- obj .: "epoch"
    r <- obj .: "revision"
    ident <- obj .: "mediaId"
    playback <- obj .: "mode"
    position <- number obj "positionSeconds"
    anchor <- number obj "anchorServerTimeMs"
    reason <- obj .: "pauseReason"
    unless (e /= "" && r >= 0 && position >= 0) $ fail "Invalid room state"
    case (playback, ident) of
      (Empty, Nothing) -> unless (position == 0) $ fail "Invalid empty position"
      (Empty, Just _) -> fail "Empty room has media"
      (_, Nothing) -> fail "Selected room has no media"
      (_, Just value) -> unless (value /= "") $ fail "Empty media identifier"
    pure $ RoomState e r ident playback position anchor reason

instance FromJSON ServerMessage where
  parseJSON value = withObject "ServerMessage" (\obj -> do
    kind <- obj .: "type" :: Parser Text
    case kind of
      "state" -> StateSnapshot <$> parseJSON value
      "pong" -> Pong <$> number obj "clientSentAtMs" <*> number obj "serverTimeMs"
      "error" -> ServerError <$> obj .: "code" <*> obj .: "message"
      _ -> fail "Unknown server message") value

instance FromJSON Movie where
  parseJSON = withObject "Movie" $ \obj -> Movie <$> obj .: "id" <*> obj .: "title" <*> obj .: "url"
instance FromJSON Catalog where
  parseJSON = withObject "Catalog" $ \obj -> Catalog <$> obj .: "movies"
