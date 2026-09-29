{-# LANGUAGE OverloadedStrings #-}
module VoiceProtocol where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

data VoiceRole = Offerer | Answerer deriving (Eq, Show)

data IceCandidate = IceCandidate
  { candidate :: Text
  , sdpMid :: Maybe Text
  , sdpMLineIndex :: Maybe Int
  } deriving (Eq, Show)

data VoiceSignal
  = VoiceOffer Text
  | VoiceAnswer Text
  | VoiceIce IceCandidate
  | VoiceLeave
  deriving (Eq, Show)

data VoiceServerMessage
  = VoiceWaiting
  | VoicePeerReady VoiceRole
  | VoiceOfferReceived Text
  | VoiceAnswerReceived Text
  | VoiceIceReceived IceCandidate
  | VoicePeerLeft
  | VoiceServerError Text Text
  deriving (Eq, Show)

data IceServer = IceServer
  { iceUrls :: [Text]
  , iceUsername :: Maybe Text
  , iceCredential :: Maybe Text
  } deriving (Eq, Show)

data VoiceIceResponse = VoiceIceResponse
  { iceServers :: [IceServer]
  , iceExpiresAt :: Maybe Integer
  } deriving (Eq, Show)

validText :: Int -> Text -> Bool
validText limit value = not (T.null value) && T.length value <= limit

instance ToJSON IceCandidate where
  toJSON value = object
    [ "candidate" .= candidate value
    , "sdpMid" .= sdpMid value
    , "sdpMLineIndex" .= sdpMLineIndex value
    ]

instance FromJSON IceCandidate where
  parseJSON = withObject "IceCandidate" parseCandidate

instance ToJSON VoiceSignal where
  toJSON signal = case signal of
    VoiceOffer sdp -> object ["type" .= String "offer", "sdp" .= sdp]
    VoiceAnswer sdp -> object ["type" .= String "answer", "sdp" .= sdp]
    VoiceIce value -> object
      [ "type" .= String "ice"
      , "candidate" .= candidate value
      , "sdpMid" .= sdpMid value
      , "sdpMLineIndex" .= sdpMLineIndex value
      ]
    VoiceLeave -> object ["type" .= String "leave"]

encodeVoiceSignal :: VoiceSignal -> Either Text BL.ByteString
encodeVoiceSignal signal = case signal of
  VoiceOffer sdp | not (validText (32 * 1024) sdp) -> Left "Invalid voice offer."
  VoiceAnswer sdp | not (validText (32 * 1024) sdp) -> Left "Invalid voice answer."
  VoiceIce value
    | not (validText (4 * 1024) $ candidate value) -> Left "Invalid ICE candidate."
    | maybe False (not . validText 256) (sdpMid value) -> Left "Invalid ICE media identifier."
    | maybe False (\index -> index < 0 || index > 65535) (sdpMLineIndex value) ->
        Left "Invalid ICE media index."
  _ -> Right $ encode signal

parseCandidate :: Object -> Parser IceCandidate
parseCandidate obj = do
  value <- IceCandidate <$> obj .: "candidate" <*> obj .:? "sdpMid" <*> obj .:? "sdpMLineIndex"
  unless (validText (4 * 1024) $ candidate value) $ fail "Invalid ICE candidate"
  validateCandidateMetadata value
  pure value

validateCandidateMetadata :: IceCandidate -> Parser ()
validateCandidateMetadata value = do
  unless (maybe True (validText 256) $ sdpMid value) $ fail "Invalid ICE media identifier"
  unless (maybe True (\index -> index >= 0 && index <= 65535) $ sdpMLineIndex value) $
    fail "Invalid ICE media index"

decodeLocalCandidate :: Text -> Either Text (Maybe IceCandidate)
decodeLocalCandidate raw = case eitherDecodeStrict' (TE.encodeUtf8 raw) of
  Left message -> Left $ T.pack message
  Right value -> first T.pack $ parseEither parseLocalCandidate value

parseLocalCandidate :: Value -> Parser (Maybe IceCandidate)
parseLocalCandidate = withObject "IceCandidate" $ \obj -> do
  value <- IceCandidate <$> obj .: "candidate" <*> obj .:? "sdpMid" <*> obj .:? "sdpMLineIndex"
  validateCandidateMetadata value
  case T.null $ candidate value of
    True -> pure Nothing
    False -> do
      unless (validText (4 * 1024) $ candidate value) $ fail "Invalid ICE candidate"
      pure $ Just value

parseSdp :: Object -> Parser Text
parseSdp obj = do
  value <- obj .: "sdp"
  unless (validText (32 * 1024) value) $ fail "Invalid session description"
  pure value

instance FromJSON VoiceServerMessage where
  parseJSON = withObject "VoiceServerMessage" $ \obj -> do
    kind <- obj .: "type" :: Parser Text
    case kind of
      "waiting" -> pure VoiceWaiting
      "peer-ready" -> do
        role <- obj .: "role" :: Parser Text
        case role of
          "offerer" -> pure $ VoicePeerReady Offerer
          "answerer" -> pure $ VoicePeerReady Answerer
          _ -> fail "Unknown voice role"
      "offer" -> VoiceOfferReceived <$> parseSdp obj
      "answer" -> VoiceAnswerReceived <$> parseSdp obj
      "ice" -> VoiceIceReceived <$> parseCandidate obj
      "peer-left" -> pure VoicePeerLeft
      "error" -> VoiceServerError <$> obj .: "code" <*> obj .: "message"
      _ -> fail "Unknown voice server message"

instance FromJSON IceServer where
  parseJSON = withObject "IceServer" $ \obj -> do
    urls <- obj .: "urls"
    username <- obj .:? "username"
    credential <- obj .:? "credential"
    unless (not (null urls) && all (validText 2048) urls) $ fail "Invalid ICE server URLs"
    case (username, credential) of
      (Nothing, Nothing) -> pure $ IceServer urls Nothing Nothing
      (Just user, Just secret) -> do
        unless (validText 1024 user && validText 1024 secret) $ fail "Invalid ICE credentials"
        pure $ IceServer urls (Just user) (Just secret)
      _ -> fail "Incomplete ICE credentials"

instance FromJSON VoiceIceResponse where
  parseJSON = withObject "VoiceIceResponse" $ \obj ->
    VoiceIceResponse <$> obj .: "iceServers" <*> obj .: "expiresAt"
