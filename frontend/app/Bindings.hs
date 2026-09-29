{-# LANGUAGE JavaScriptFFI, OverloadedStrings, RecursiveDo #-}
-- Browser primitives only. All timing, synchronization and recovery policy is Haskell.
module Bindings where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.JSString as JS
import GHCJS.Types (JSVal)
import GHCJS.Foreign.Callback

toJS :: Text -> JS.JSString
toJS = JS.pack . T.unpack
fromJS :: JS.JSString -> Text
fromJS = T.pack . JS.unpack

foreign import javascript unsafe "requestAnimationFrame($1)" nextFrameJS :: Callback (IO ()) -> IO ()

-- Reflex's post-build can precede attachment of the root DocumentFragment.
afterMount :: IO () -> IO ()
afterMount action = mdo
  callback <- asyncCallback $ releaseCallback callback >> action
  nextFrameJS callback

foreign import javascript unsafe "performance.timeOrigin + performance.now()" now :: IO Double
foreign import javascript unsafe "String($1)" stringValue :: JSVal -> JS.JSString
foreign import javascript unsafe "document.getElementById($1)[$2]" numberProperty :: JS.JSString -> JS.JSString -> IO Double
foreign import javascript unsafe "document.getElementById($1)[$2]" boolProperty :: JS.JSString -> JS.JSString -> IO Bool
foreign import javascript unsafe "document.getElementById($1)[$2]" textProperty :: JS.JSString -> JS.JSString -> IO JS.JSString
foreign import javascript unsafe "document.getElementById($1)[$2] = $3" setNumber :: JS.JSString -> JS.JSString -> Double -> IO ()
foreign import javascript unsafe "document.getElementById($1)[$2] = $3" setText :: JS.JSString -> JS.JSString -> JS.JSString -> IO ()
foreign import javascript unsafe "document.getElementById($1)[$2] = $3" setBool :: JS.JSString -> JS.JSString -> Bool -> IO ()
foreign import javascript unsafe "document.activeElement === document.getElementById($1)" isActive :: JS.JSString -> IO Bool
foreign import javascript unsafe "document.getElementById('video').pause()" pauseVideo :: IO ()
foreign import javascript unsafe "document.getElementById('video').load()" loadVideo :: IO ()
foreign import javascript unsafe "document.getElementById('video').removeAttribute('src')" clearVideo :: IO ()
foreign import javascript unsafe "document.getElementById('video').error !== null" videoFailed :: IO Bool

foreign import javascript unsafe
  "document.getElementById($1).addEventListener($2,$3)"
  addListener :: JS.JSString -> JS.JSString -> Callback (IO ()) -> IO ()

listen :: Text -> Text -> IO () -> IO ()
listen ident event action = do
  callback <- asyncCallback action
  addListener (toJS ident) (toJS event) callback

foreign import javascript unsafe
  "fetch('/api/movies').then(function(r){if(r.ok){return r.text();}else{throw new Error('Cannot load movie catalog');}}).then($1,function(e){$2(String(e));})"
  fetchCatalogJS :: Callback (JSVal -> IO ()) -> Callback (JSVal -> IO ()) -> IO ()

fetchCatalog :: (Either Text Text -> IO ()) -> IO ()
fetchCatalog done = mdo
  success <- asyncCallback1 $ \v -> release >> done (Right $ fromJS $ stringValue v)
  failure <- asyncCallback1 $ \v -> release >> done (Left $ fromJS $ stringValue v)
  let release = releaseCallback success >> releaseCallback failure
  fetchCatalogJS success failure

foreign import javascript unsafe
  "new WebSocket((function(){switch(location.protocol){case 'https:':return 'wss://';case 'http:':return 'ws://';default:throw new Error('Unsupported protocol');}})() + location.host + $1)"
  newSocketAt :: JS.JSString -> IO JSVal
foreign import javascript unsafe
  "$1.onopen = $2; $1.onmessage = function(e){$3(e.data);}; $1.onclose = $4; $1.onerror = function(){$1.close();};"
  watchSocket :: JSVal -> Callback (IO ()) -> Callback (JSVal -> IO ()) -> Callback (IO ()) -> IO ()
foreign import javascript unsafe "$1.readyState === 1" socketOpen :: JSVal -> IO Bool
foreign import javascript unsafe "$1.send($2)" socketSend :: JSVal -> JS.JSString -> IO ()
foreign import javascript unsafe "$1.close()" socketClose :: JSVal -> IO ()
foreign import javascript unsafe "$1.onopen = null; $1.onmessage = null; $1.onclose = null; $1.onerror = null;" unwatchSocket :: JSVal -> IO ()

connectSocketAt :: Text -> IO () -> (Text -> IO ()) -> IO () -> IO JSVal
connectSocketAt path opened message closed = mdo
  socket <- newSocketAt $ toJS path
  onOpen <- asyncCallback opened
  onMessage <- asyncCallback1 $ message . fromJS . stringValue
  onClose <- asyncCallback $ do
    unwatchSocket socket
    releaseCallback onOpen
    releaseCallback onMessage
    releaseCallback onClose
    closed
  watchSocket socket onOpen onMessage onClose
  pure socket

connectSocket :: IO () -> (Text -> IO ()) -> IO () -> IO JSVal
connectSocket = connectSocketAt "/room"

foreign import javascript unsafe
  "try{document.getElementById('video').play().then(function(){$1('');},function(e){$1(e.name + ': ' + e.message);});}catch(e){$1(e.name + ': ' + e.message);}"
  playJS :: Callback (JSVal -> IO ()) -> IO ()

playVideo :: (Text -> IO ()) -> IO ()
playVideo done = mdo
  callback <- asyncCallback1 $ \v -> releaseCallback callback >> done (fromJS $ stringValue v)
  playJS callback

foreign import javascript unsafe
  "try{var p;if(document.fullscreenElement){p=document.exitFullscreen();}else if(document.getElementById('player').requestFullscreen){p=document.getElementById('player').requestFullscreen();}else{throw new Error('Fullscreen is unavailable in this browser.');}Promise.resolve(p).then(function(){$1('');},function(e){$1(String(e));});}catch(e){$1(String(e));}"
  fullscreenJS :: Callback (JSVal -> IO ()) -> IO ()

fullscreen :: (Text -> IO ()) -> IO ()
fullscreen done = mdo
  callback <- asyncCallback1 $ \v -> releaseCallback callback >> done (fromJS $ stringValue v)
  fullscreenJS callback

foreign import javascript unsafe "document.fullscreenElement !== null" isFullscreen :: IO Bool
