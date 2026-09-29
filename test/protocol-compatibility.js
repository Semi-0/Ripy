import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { on } from 'node:events';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { buildServer } from '../src/server.js';
import { decodeAndValidate } from '../src/protocol.js';
import { decodeVoiceMessage } from '../src/voice-protocol.js';

const directory = await mkdtemp(join(tmpdir(), 'ripy-compatibility-'));
await writeFile(join(directory, 'test.mp4'), 'fixture');
const app = await buildServer({ mediaDirectory: directory });
let socket;
let incoming;
let voiceA;
let voiceB;
let voiceIncomingA;
let voiceIncomingB;
try {
  await app.ready();
  socket = await app.injectWS('/room', {}, {
    onInit(client) { incoming = on(client, 'message'); }
  });
  const next = async () => JSON.parse((await incoming.next()).value[0].toString());
  const snapshots = [await next()];
  for (const command of [{ type: 'select', mediaId: 'test.mp4' }, { type: 'play' }, { type: 'pause', reason: 'buffering' }]) {
    socket.send(JSON.stringify(command));
    snapshots.push(await next());
  }
  const fixture = join(directory, 'snapshots.json');
  await writeFile(fixture, JSON.stringify(snapshots));
  voiceA = await app.injectWS('/voice', {}, {
    onInit(client) { voiceIncomingA = on(client, 'message'); }
  });
  const nextVoiceA = async () => JSON.parse((await voiceIncomingA.next()).value[0].toString());
  const voiceMessages = [await nextVoiceA()];
  voiceB = await app.injectWS('/voice', {}, {
    onInit(client) { voiceIncomingB = on(client, 'message'); }
  });
  const nextVoiceB = async () => JSON.parse((await voiceIncomingB.next()).value[0].toString());
  voiceMessages.push(await nextVoiceA(), await nextVoiceB());
  voiceA.send(JSON.stringify({ type: 'offer', sdp: 'offer-sdp' }));
  voiceMessages.push(await nextVoiceB());
  voiceB.send(JSON.stringify({ type: 'answer', sdp: 'answer-sdp' }));
  voiceMessages.push(await nextVoiceA());
  voiceA.send(JSON.stringify({
    type: 'ice',
    candidate: 'candidate:1 1 UDP 1 127.0.0.1 9 typ host',
    sdpMid: '0',
    sdpMLineIndex: 0
  }));
  voiceMessages.push(await nextVoiceB());
  voiceB.send(JSON.stringify({ type: 'leave' }));
  voiceMessages.push(await nextVoiceA());
  const voiceFixture = join(directory, 'voice-messages.json');
  await writeFile(voiceFixture, JSON.stringify(voiceMessages));

  const output = execFileSync(resolve(process.argv[2]), [fixture, voiceFixture],
    { encoding: 'utf8', timeout: 30000 });
  const encoded = output.trim().split('\n');
  const commands = encoded.slice(0, 7).map(line => decodeAndValidate(line));
  assert.deepEqual(commands, [
    { type: 'select', mediaId: 'test.mp4' }, { type: 'play' },
    { type: 'pause', reason: 'user' }, { type: 'pause', reason: 'buffering' },
    { type: 'pause', reason: 'ended' }, { type: 'seek', positionSeconds: 12.5 },
    { type: 'ping', clientSentAtMs: 1000 }
  ]);
  const voiceCommands = encoded.slice(7).map(line => decodeVoiceMessage(line));
  assert.deepEqual(voiceCommands, [
    { type: 'offer', sdp: 'offer-sdp' },
    { type: 'answer', sdp: 'answer-sdp' },
    {
      type: 'ice',
      candidate: 'candidate:1 1 UDP 1 127.0.0.1 9 typ host',
      sdpMid: '0',
      sdpMLineIndex: 0
    },
    { type: 'leave' }
  ]);
  console.log('PASS actual Fastify movie and voice messages decoded by Haskell; Haskell messages accepted by actual JS validators');
} finally {
  if (socket !== undefined) {
    await incoming.return();
    socket.terminate();
  } else {
    // Connection setup failed before a socket was allocated.
  }
  if (voiceIncomingA !== undefined) {
    await voiceIncomingA.return();
    voiceA.terminate();
  } else {
    // Voice connection A was never allocated.
  }
  if (voiceIncomingB !== undefined) {
    await voiceIncomingB.return();
    voiceB.terminate();
  } else {
    // Voice connection B was never allocated.
  }
  for (const client of app.websocketServer.clients) {
    client.terminate();
  }
  await app.close();
  await rm(directory, { recursive: true, force: true });
}
