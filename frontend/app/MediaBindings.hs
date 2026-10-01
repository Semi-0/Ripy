{-# LANGUAGE JavaScriptFFI, OverloadedStrings, RecursiveDo #-}
module MediaBindings
  ( fetchMediaAccess, uploadSelectedMedia, openMediaEvents
  , createAdminSession, deleteAdminSession, deleteMedia
  ) where

import Data.Text (Text)
import qualified Data.JSString as JS
import GHCJS.Foreign.Callback
import GHCJS.Types (JSVal)
import Bindings (fromJS, stringValue, toJS)

foreign import javascript unsafe
  "fetch('/api/media/access',{credentials:'same-origin'}).then(function(r){return r.text().then(function(t){if(r.ok){$1(t);}else{if(t!==''){$2(t);}else{$2('HTTP '+r.status);}}});},function(e){$2(String(e));})"
  fetchMediaAccessJS :: Callback (JSVal -> IO ()) -> Callback (JSVal -> IO ()) -> IO ()

fetchMediaAccess :: (Either Text Text -> IO ()) -> IO ()
fetchMediaAccess done = withResult fetchMediaAccessJS done

foreign import javascript unsafe
  "(function(progress,success,failure){var input=document.getElementById('media-file');var file=input&&input.files&&input.files[0];if(!file){failure('Choose an MP4 file first.');return;}var xhr=new XMLHttpRequest();xhr.open('PUT','/api/media/'+encodeURIComponent(file.name));xhr.setRequestHeader('Content-Type',(function(){if(file.type==='video/mp4'){return 'video/mp4';}else{return 'application/octet-stream';}})());xhr.upload.onprogress=function(e){if(e.lengthComputable&&e.total>0){progress(e.loaded/e.total);}};xhr.onload=function(){if(xhr.status>=200&&xhr.status<300){success(file.name);}else{try{var body=JSON.parse(xhr.responseText);if(typeof body.error==='string'&&body.error!==''){failure(body.error);}else{failure('HTTP '+xhr.status);}}catch(_e){if(xhr.responseText!==''){failure(xhr.responseText);}else{failure('HTTP '+xhr.status);}}}};xhr.onerror=function(){failure('Upload connection failed.');};xhr.onabort=function(){failure('Upload was cancelled.');};xhr.send(file);})($1,$2,$3)"
  uploadSelectedMediaJS
    :: Callback (JSVal -> IO ())
    -> Callback (JSVal -> IO ())
    -> Callback (JSVal -> IO ())
    -> IO ()

uploadSelectedMedia :: (Double -> IO ()) -> (Either Text Text -> IO ()) -> IO ()
uploadSelectedMedia progress done = mdo
  onProgress <- asyncCallback1 $ progress . numberValue
  success <- asyncCallback1 $ \value -> release >> done (Right $ fromJS $ stringValue value)
  failure <- asyncCallback1 $ \value -> release >> done (Left $ fromJS $ stringValue value)
  let release = releaseCallback onProgress >> releaseCallback success >> releaseCallback failure
  uploadSelectedMediaJS onProgress success failure

foreign import javascript unsafe "Number($1)" numberValue :: JSVal -> Double

foreign import javascript unsafe
  "(function(changed,failed){var source=new EventSource('/api/media/events');source.onmessage=function(){changed();};source.onerror=function(){failed('Catalog updates disconnected; retrying.');};})($1,$2)"
  openMediaEventsJS :: Callback (IO ()) -> Callback (JSVal -> IO ()) -> IO ()

openMediaEvents :: IO () -> (Text -> IO ()) -> IO ()
openMediaEvents changed failed = do
  onChanged <- asyncCallback changed
  onFailed <- asyncCallback1 $ failed . fromJS . stringValue
  openMediaEventsJS onChanged onFailed

foreign import javascript unsafe
  "fetch('/api/media/admin/session',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:$1})}).then(function(r){return r.text().then(function(t){if(r.ok){$2(t);}else{try{var b=JSON.parse(t);if(typeof b.error==='string'&&b.error!==''){$3(b.error);}else{$3('HTTP '+r.status);}}catch(_e){if(t!==''){$3(t);}else{$3('HTTP '+r.status);}}}});},function(e){$3(String(e));})"
  createAdminSessionJS
    :: JS.JSString -> Callback (JSVal -> IO ()) -> Callback (JSVal -> IO ()) -> IO ()

createAdminSession :: Text -> (Either Text Text -> IO ()) -> IO ()
createAdminSession password done = withResult (createAdminSessionJS $ toJS password) done

foreign import javascript unsafe
  "fetch('/api/media/admin/session',{method:'DELETE',credentials:'same-origin'}).then(function(r){return r.text().then(function(t){if(r.ok){$1(t);}else{try{var b=JSON.parse(t);if(typeof b.error==='string'&&b.error!==''){$2(b.error);}else{$2('HTTP '+r.status);}}catch(_e){if(t!==''){$2(t);}else{$2('HTTP '+r.status);}}}});},function(e){$2(String(e));})"
  deleteAdminSessionJS :: Callback (JSVal -> IO ()) -> Callback (JSVal -> IO ()) -> IO ()

deleteAdminSession :: (Either Text Text -> IO ()) -> IO ()
deleteAdminSession done = withResult deleteAdminSessionJS done

foreign import javascript unsafe
  "(function(name,success,failure){if(!confirm('Delete '+name+'?')){failure('Deletion cancelled.');return;}fetch('/api/media/'+encodeURIComponent(name),{method:'DELETE',credentials:'same-origin'}).then(function(r){return r.text().then(function(t){if(r.ok){success(name);}else{try{var b=JSON.parse(t);if(typeof b.error==='string'&&b.error!==''){failure(b.error);}else{failure('HTTP '+r.status);}}catch(_e){if(t!==''){failure(t);}else{failure('HTTP '+r.status);}}}});},function(e){failure(String(e));});})($1,$2,$3)"
  deleteMediaJS
    :: JS.JSString -> Callback (JSVal -> IO ()) -> Callback (JSVal -> IO ()) -> IO ()

deleteMedia :: Text -> (Either Text Text -> IO ()) -> IO ()
deleteMedia filename done = withResult (deleteMediaJS $ toJS filename) done

withResult
  :: (Callback (JSVal -> IO ()) -> Callback (JSVal -> IO ()) -> IO ())
  -> (Either Text Text -> IO ())
  -> IO ()
withResult operation done = mdo
  success <- asyncCallback1 $ \value -> release >> done (Right $ fromJS $ stringValue value)
  failure <- asyncCallback1 $ \value -> release >> done (Left $ fromJS $ stringValue value)
  let release = releaseCallback success >> releaseCallback failure
  operation success failure
