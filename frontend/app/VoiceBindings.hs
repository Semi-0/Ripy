{-# LANGUAGE JavaScriptFFI, OverloadedStrings, RecursiveDo #-}
module VoiceBindings
  ( BrowserPeer, fetchVoiceIce, requestVoiceMedia, createVoicePeer
  , makeVoiceOffer, answerVoiceOffer, acceptVoiceAnswer, addVoiceCandidate
  , setVoiceMuted, stopVoiceMedia, enableVoiceAudio, clearVoiceAudio
  , closeVoicePeer
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.JSString as JS
import GHCJS.Foreign.Callback
import GHCJS.Types (JSVal)
import Bindings (fromJS, stringValue, toJS)

data BrowserPeer = BrowserPeer
  { peerValue :: JSVal
  , closeVoicePeer :: IO ()
  }

foreign import javascript unsafe
  "fetch('/api/voice/ice',{cache:'no-store'}).then(function(r){if(r.ok){return r.text();}else{throw new Error('Cannot load voice configuration');}}).then($1,function(e){$2(String(e));})"
  fetchVoiceIceJS :: Callback (JSVal -> IO ()) -> Callback (JSVal -> IO ()) -> IO ()

fetchVoiceIce :: (Either Text Text -> IO ()) -> IO ()
fetchVoiceIce done = mdo
  success <- asyncCallback1 $ \value -> release >> done (Right $ fromJS $ stringValue value)
  failure <- asyncCallback1 $ \value -> release >> done (Left $ fromJS $ stringValue value)
  let release = releaseCallback success >> releaseCallback failure
  fetchVoiceIceJS success failure

foreign import javascript unsafe
  "(function(){try{if(typeof RTCPeerConnection==='undefined'){throw new Error('WebRTC is unavailable in this browser.');}if(!navigator.mediaDevices||!navigator.mediaDevices.getUserMedia){throw new Error('Microphone access requires HTTPS or localhost.');}navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true},video:false}).then($1,function(e){$2(e.name + ': ' + e.message);});}catch(e){$2(e.name + ': ' + e.message);}})()"
  requestVoiceMediaJS :: Callback (JSVal -> IO ()) -> Callback (JSVal -> IO ()) -> IO ()

requestVoiceMedia :: (Either Text JSVal -> IO ()) -> IO ()
requestVoiceMedia done = mdo
  success <- asyncCallback1 $ \value -> release >> done (Right value)
  failure <- asyncCallback1 $ \value -> release >> done (Left $ fromJS $ stringValue value)
  let release = releaseCallback success >> releaseCallback failure
  requestVoiceMediaJS success failure

foreign import javascript unsafe
  "new RTCPeerConnection({iceServers:JSON.parse($1).iceServers})"
  newVoicePeerJS :: JS.JSString -> IO JSVal
foreign import javascript unsafe
  "$2.getTracks().forEach(function(track){$1.addTrack(track,$2);})"
  addVoiceTracksJS :: JSVal -> JSVal -> IO ()
foreign import javascript unsafe
  "$1.onicecandidate=function(e){if(e.candidate){$2(JSON.stringify(e.candidate.toJSON()));}};$1.ontrack=function(e){var a=document.getElementById('voice-audio');a.srcObject=e.streams[0];Promise.resolve(a.play()).then(function(){$3('');},function(x){$3(x.name + ': ' + x.message);});};$1.onconnectionstatechange=function(){$4($1.connectionState);};"
  watchVoicePeerJS :: JSVal -> Callback (JSVal -> IO ()) -> Callback (JSVal -> IO ()) -> Callback (JSVal -> IO ()) -> IO ()
foreign import javascript unsafe
  "$1.onicecandidate=null;$1.ontrack=null;$1.onconnectionstatechange=null;$1.close();"
  closeVoicePeerJS :: JSVal -> IO ()
foreign import javascript unsafe
  "(function(){var active=true,busy=false,lastEnergy=null,lastDuration=null;var timer=setInterval(function(){if(!active||busy){return;}busy=true;try{Promise.resolve($1.getStats()).then(function(stats){var level=0,found=false;stats.forEach(function(report){if(report.type==='inbound-rtp'&&(report.kind==='audio'||report.mediaType==='audio')&&!report.isRemote){found=true;if(Number.isFinite(report.audioLevel)&&report.audioLevel>=0){level=Math.max(level,report.audioLevel);}else if(Number.isFinite(report.totalAudioEnergy)&&Number.isFinite(report.totalSamplesDuration)){if(lastEnergy!==null&&lastDuration!==null){var energy=report.totalAudioEnergy-lastEnergy;var duration=report.totalSamplesDuration-lastDuration;if(energy>=0&&duration>0){level=Math.max(level,Math.sqrt(energy/duration));}}lastEnergy=report.totalAudioEnergy;lastDuration=report.totalSamplesDuration;}}});if(active){var sample=0;if(found&&Number.isFinite(level)&&level>=0){sample=level;}else{sample=0;}$2(sample);}},function(){if(active){$2(0);}}).then(function(){busy=false;},function(){busy=false;});}catch(e){busy=false;if(active){$2(0);}}},100);return {stop:function(){active=false;clearInterval(timer);}};})()"
  startRemoteLevelMonitorJS :: JSVal -> Callback (Double -> IO ()) -> IO JSVal
foreign import javascript unsafe "$1.stop()"
  stopRemoteLevelMonitorJS :: JSVal -> IO ()

createVoicePeer
  :: Text -> JSVal -> (Text -> IO ()) -> (Either Text () -> IO ())
  -> (Double -> IO ()) -> (Text -> IO ())
  -> IO BrowserPeer
createVoicePeer configuration stream onIce onPlayback onLevel onState = mdo
  peer <- newVoicePeerJS $ toJS configuration
  iceCallback <- asyncCallback1 $ onIce . fromJS . stringValue
  playbackCallback <- asyncCallback1 $ \value ->
    let message = fromJS $ stringValue value
    in if T.null message then onPlayback (Right ()) else onPlayback (Left message)
  levelCallback <- asyncCallback1 onLevel
  stateCallback <- asyncCallback1 $ onState . fromJS . stringValue
  addVoiceTracksJS peer stream
  watchVoicePeerJS peer iceCallback playbackCallback stateCallback
  monitor <- startRemoteLevelMonitorJS peer levelCallback
  let close = do
        stopRemoteLevelMonitorJS monitor
        closeVoicePeerJS peer
        releaseCallback iceCallback
        releaseCallback playbackCallback
        releaseCallback levelCallback
        releaseCallback stateCallback
  pure $ BrowserPeer peer close

foreign import javascript unsafe
  "$1.createOffer().then(function(d){return $1.setLocalDescription(d).then(function(){return d.sdp;});}).then($2,function(e){$3(e.name + ': ' + e.message);});"
  makeVoiceOfferJS :: JSVal -> Callback (JSVal -> IO ()) -> Callback (JSVal -> IO ()) -> IO ()
foreign import javascript unsafe
  "$1.setRemoteDescription({type:'offer',sdp:$2}).then(function(){return $1.createAnswer();}).then(function(d){return $1.setLocalDescription(d).then(function(){return d.sdp;});}).then($3,function(e){$4(e.name + ': ' + e.message);});"
  answerVoiceOfferJS :: JSVal -> JS.JSString -> Callback (JSVal -> IO ()) -> Callback (JSVal -> IO ()) -> IO ()
foreign import javascript unsafe
  "$1.setRemoteDescription({type:'answer',sdp:$2}).then(function(){$3('');},function(e){$3(e.name + ': ' + e.message);});"
  acceptVoiceAnswerJS :: JSVal -> JS.JSString -> Callback (JSVal -> IO ()) -> IO ()
foreign import javascript unsafe
  "$1.addIceCandidate(JSON.parse($2)).then(function(){$3('');},function(e){$3(e.name + ': ' + e.message);});"
  addVoiceCandidateJS :: JSVal -> JS.JSString -> Callback (JSVal -> IO ()) -> IO ()

textResult
  :: (Callback (JSVal -> IO ()) -> Callback (JSVal -> IO ()) -> IO ())
  -> (Either Text Text -> IO ()) -> IO ()
textResult operation done = mdo
  success <- asyncCallback1 $ \value -> release >> done (Right $ fromJS $ stringValue value)
  failure <- asyncCallback1 $ \value -> release >> done (Left $ fromJS $ stringValue value)
  let release = releaseCallback success >> releaseCallback failure
  operation success failure

unitResult :: (Callback (JSVal -> IO ()) -> IO ()) -> (Either Text () -> IO ()) -> IO ()
unitResult operation done = mdo
  callback <- asyncCallback1 $ \value -> do
    releaseCallback callback
    let message = fromJS $ stringValue value
    if T.null message then done (Right ()) else done (Left message)
  operation callback

makeVoiceOffer :: BrowserPeer -> (Either Text Text -> IO ()) -> IO ()
makeVoiceOffer peer = textResult $ makeVoiceOfferJS $ peerValue peer

answerVoiceOffer :: BrowserPeer -> Text -> (Either Text Text -> IO ()) -> IO ()
answerVoiceOffer peer sdp = textResult $ answerVoiceOfferJS (peerValue peer) (toJS sdp)

acceptVoiceAnswer :: BrowserPeer -> Text -> (Either Text () -> IO ()) -> IO ()
acceptVoiceAnswer peer sdp = unitResult $ acceptVoiceAnswerJS (peerValue peer) (toJS sdp)

addVoiceCandidate :: BrowserPeer -> Text -> (Either Text () -> IO ()) -> IO ()
addVoiceCandidate peer value = unitResult $ addVoiceCandidateJS (peerValue peer) (toJS value)

foreign import javascript unsafe
  "$1.getAudioTracks().forEach(function(track){track.enabled=!$2;})"
  setVoiceMutedJS :: JSVal -> Bool -> IO ()
foreign import javascript unsafe
  "$1.getTracks().forEach(function(track){track.stop();})"
  stopVoiceMedia :: JSVal -> IO ()
foreign import javascript unsafe
  "(function(){var a=document.getElementById('voice-audio');a.pause();a.srcObject=null;})()"
  clearVoiceAudio :: IO ()
foreign import javascript unsafe
  "(function(){var a=document.getElementById('voice-audio');Promise.resolve(a.play()).then(function(){$1('');},function(e){$1(e.name + ': ' + e.message);});})()"
  enableVoiceAudioJS :: Callback (JSVal -> IO ()) -> IO ()

setVoiceMuted :: JSVal -> Bool -> IO ()
setVoiceMuted = setVoiceMutedJS

enableVoiceAudio :: (Either Text () -> IO ()) -> IO ()
enableVoiceAudio = unitResult enableVoiceAudioJS
