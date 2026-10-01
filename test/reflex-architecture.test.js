import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../', import.meta.url);

async function source(path) {
  return readFile(new URL(path, root), 'utf8');
}

function imports(moduleName) {
  return new RegExp(`^import(?: qualified)? ${moduleName}(?:\\s|$)`, 'm');
}

test('atomic View has no application or domain dependencies', async () => {
  const view = await source('frontend/app/View.hs');
  for (const moduleName of ['Catalog', 'Connection', 'MovieView', 'Network', 'Player', 'Protocol', 'Selection', 'Voice', 'VoiceView']) {
    assert.doesNotMatch(view, imports(moduleName));
  }
  assert.match(view, /^buttonView ::/m);
  assert.match(view, /^choiceView ::/m);
  assert.match(view, /^rangeView ::/m);
});

test('VoiceView composes presentation without behavior dependencies', async () => {
  const voiceView = await source('frontend/app/VoiceView.hs');
  for (const moduleName of ['Catalog', 'Connection', 'MovieView', 'Network', 'Player', 'Protocol', 'Voice', 'VoiceProtocol']) {
    assert.doesNotMatch(voiceView, imports(moduleName));
  }
  assert.doesNotMatch(voiceView, /\b(?:RTCPeerConnection|VoiceSignal|VoicePhase)\b/);
  assert.match(voiceView, /^data VoiceSignals t/m);
});

test('voice behavior is independent from the movie player and room', async () => {
  const voice = await source('frontend/app/Voice.hs');
  const player = await source('frontend/app/Player.hs');
  for (const moduleName of ['Connection', 'MovieView', 'Network', 'Player', 'Protocol']) {
    assert.doesNotMatch(voice, imports(moduleName));
  }
  assert.doesNotMatch(player, imports('Voice'));
  assert.doesNotMatch(player, imports('Ducking'));
  assert.match(voice, /^voiceController ::/m);
  assert.match(voice, /voiceRemoteSpeaking :: Dynamic t Bool/);
});

test('ducking policy is pure and composed only by Main', async () => {
  const ducking = await source('frontend/src/Ducking.hs');
  const main = await source('frontend/app/Main.hs');
  assert.doesNotMatch(ducking, /^(?:foreign import|import Reflex|import Voice|import Player)/m);
  assert.match(ducking, /^observeRemoteLevel\s*::/m);
  assert.match(ducking, /^effectiveMovieVolume ::/m);
  assert.match(main, /voiceRemoteSpeaking voice/);
  assert.match(main, /effectiveMovieVolume defaultDuckingPolicy/);
  assert.match(main, /videoVolumes = updated effectiveVolume/);
});

test('MovieView composes presentation without behavior dependencies', async () => {
  const movieView = await source('frontend/app/MovieView.hs');
  for (const moduleName of ['Catalog', 'Connection', 'Network', 'Player', 'Protocol']) {
    assert.doesNotMatch(movieView, imports(moduleName));
  }
  assert.doesNotMatch(movieView, /\b(?:ClientCommand|Reaction|SendCommand)\b/);
  assert.match(movieView, /^data MovieSignals t/m);
});

test('Network does not depend on presentation modules', async () => {
  const network = await source('frontend/app/Network.hs');
  assert.doesNotMatch(network, imports('View'));
  assert.doesNotMatch(network, imports('MovieView'));
});

test('Main is the movie and voice behavior specialization boundary', async () => {
  const main = await source('frontend/app/Main.hs');
  assert.match(main, /^specializeMovieSignals ::/m);
  assert.match(main, /Protocol\.SelectMovie/);
  assert.match(main, /playerMediaCommands/);
  assert.match(main, /^voicePresentation ::/m);
  assert.match(main, /controlVoice VoiceInputs/);
});


test('media management keeps view, behavior and effects separated', async () => {
  const model = await source('frontend/src/MediaManagement.hs');
  const transfer = await source('frontend/app/MediaTransfer.hs');
  const bindings = await source('frontend/app/MediaBindings.hs');
  const view = await source('frontend/app/MediaManagementView.hs');
  const player = await source('frontend/app/Player.hs');
  const voice = await source('frontend/app/Voice.hs');
  const main = await source('frontend/app/Main.hs');
  assert.doesNotMatch(model, /^(?:foreign import|import Reflex)/m);
  assert.doesNotMatch(view, /^(?:foreign import|import MediaTransfer|import MediaBindings|import Player|import Voice)/m);
  assert.doesNotMatch(transfer, imports('Player'));
  assert.doesNotMatch(transfer, imports('Voice'));
  assert.doesNotMatch(player, imports('MediaTransfer'));
  assert.doesNotMatch(voice, imports('MediaTransfer'));
  assert.match(bindings, /foreign import javascript/);
  assert.match(main, /mediaManagementController/);
  assert.match(main, /controlMediaManagement MediaManagementInputs/);
  assert.match(main, /catalogNetwork \$ mediaCatalogChanged mediaManagement/);
  assert.match(main, /^administratorStatus :: MediaAccess -> Text/m);
  assert.match(view, /adminStatusText :: Text/);
});
