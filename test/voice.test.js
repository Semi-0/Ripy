import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildServer } from '../src/server.js';
import { decodeVoiceMessage, VoiceProtocolError } from '../src/voice-protocol.js';
import { createVoiceIceResponse, readVoiceIceConfiguration } from '../src/voice-ice.js';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'voice-test-'));
  const mediaDirectory = join(directory, 'media');
  const frontendDirectory = join(directory, 'frontend');
  await mkdir(mediaDirectory);
  await mkdir(frontendDirectory);
  await writeFile(join(frontendDirectory, 'index.html'), '<main>voice fixture</main>');
  await writeFile(join(frontendDirectory, 'all.js'), '// fixture');
  const app = await buildServer({
    mediaDirectory,
    frontendDirectory,
    now: () => 1_700_000_000_000,
    voiceIceConfiguration: {
      stunUrls: ['stun:voice.example:3478'],
      turnUrls: ['turn:voice.example:3478'],
      turnSharedSecret: 'test-secret',
      ttlSeconds: 600
    }
  });
  await app.ready();
  t.after(async () => {
    for (const client of app.websocketServer.clients) {
      client.terminate();
    }
    await app.close();
    await rm(directory, { recursive: true, force: true });
  });
  return app;
}

async function voicePeer(app, t) {
  const queued = [];
  let waiting = null;
  const socket = await app.injectWS('/voice', {}, {
    onInit(client) {
      client.on('message', (bytes) => {
        const message = JSON.parse(bytes.toString());
        if (waiting === null) {
          queued.push(message);
        } else {
          const resolve = waiting;
          waiting = null;
          resolve(message);
        }
      });
    }
  });
  t.after(() => socket.terminate());
  return {
    socket,
    send(message) { socket.send(JSON.stringify(message)); },
    next() {
      if (queued.length > 0) {
        return Promise.resolve(queued.shift());
      } else {
        return new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('Timed out waiting for voice message')), 2000);
          waiting = (message) => { clearTimeout(timer); resolve(message); };
        });
      }
    }
  };
}

test('voice protocol validates strict bounded messages', () => {
  assert.deepEqual(decodeVoiceMessage('{"type":"leave"}'), { type: 'leave' });
  assert.deepEqual(decodeVoiceMessage('{"type":"ice","candidate":"candidate:1","sdpMid":null,"sdpMLineIndex":0}'),
    { type: 'ice', candidate: 'candidate:1', sdpMid: null, sdpMLineIndex: 0 });
  for (const input of ['{', '{}', '{"type":"leave","extra":1}',
    '{"type":"offer","sdp":""}', '{"type":"ice","candidate":"x","sdpMLineIndex":-1}']) {
    assert.throws(() => decodeVoiceMessage(input), VoiceProtocolError);
  }
});

test('TURN response uses expiring credentials and never exposes its secret', () => {
  const configuration = readVoiceIceConfiguration({
    VOICE_STUN_URLS: 'stun:a.example, stun:b.example',
    VOICE_TURN_URLS: 'turn:a.example,turns:a.example',
    VOICE_TURN_SHARED_SECRET: 'shared',
    VOICE_TURN_TTL_SECONDS: '600'
  });
  const response = createVoiceIceResponse(configuration, () => 1_700_000_000_000);
  const username = '1700000600:ripy';
  assert.deepEqual(response, {
    iceServers: [
      { urls: ['stun:a.example', 'stun:b.example'] },
      {
        urls: ['turn:a.example', 'turns:a.example'],
        username,
        credential: createHmac('sha1', 'shared').update(username).digest('base64')
      }
    ],
    expiresAt: 1_700_000_600_000
  });
  assert.doesNotMatch(JSON.stringify(response), /shared/);
  assert.throws(() => readVoiceIceConfiguration({ VOICE_TURN_URLS: 'turn:a.example' }),
    /configured together/);
});

test('voice route pairs two peers, enforces roles, relays signals, and cleans up', async (t) => {
  const app = await fixture(t);
  const first = await voicePeer(app, t);
  assert.deepEqual(await first.next(), { type: 'waiting' });
  const second = await voicePeer(app, t);
  assert.deepEqual(await first.next(), { type: 'peer-ready', role: 'offerer' });
  assert.deepEqual(await second.next(), { type: 'peer-ready', role: 'answerer' });

  second.send({ type: 'offer', sdp: 'wrong-role' });
  assert.equal((await second.next()).code, 'INVALID_ROLE');
  first.send({ type: 'offer', sdp: 'offer-sdp' });
  assert.deepEqual(await second.next(), { type: 'offer', sdp: 'offer-sdp' });
  second.send({ type: 'answer', sdp: 'answer-sdp' });
  assert.deepEqual(await first.next(), { type: 'answer', sdp: 'answer-sdp' });
  first.send({ type: 'ice', candidate: 'candidate:1', sdpMid: '0', sdpMLineIndex: 0 });
  assert.deepEqual(await second.next(),
    { type: 'ice', candidate: 'candidate:1', sdpMid: '0', sdpMLineIndex: 0 });

  second.socket.terminate();
  assert.deepEqual(await first.next(), { type: 'peer-left' });
  assert.deepEqual(await first.next(), { type: 'waiting' });
});

test('voice route rejects a third participant and serves no-store ICE configuration', async (t) => {
  const app = await fixture(t);
  const first = await voicePeer(app, t);
  await first.next();
  const second = await voicePeer(app, t);
  await first.next();
  await second.next();
  const third = await voicePeer(app, t);
  assert.equal((await third.next()).code, 'ROOM_FULL');
  const response = await app.inject('/api/voice/ice');
  assert.equal(response.headers['cache-control'], 'no-store');
  assert.equal(response.json().iceServers.length, 2);
});
