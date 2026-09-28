import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { on } from 'node:events';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { buildServer } from '../src/server.js';
import { decodeAndValidate } from '../src/protocol.js';

const directory = await mkdtemp(join(tmpdir(), 'ripy-compatibility-'));
await writeFile(join(directory, 'test.mp4'), 'fixture');
const app = await buildServer({ mediaDirectory: directory });
let socket;
let incoming;
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
  const output = execFileSync(resolve(process.argv[2]), [fixture], { encoding: 'utf8', timeout: 30000 });
  const commands = output.trim().split('\n').map(line => decodeAndValidate(line));
  assert.deepEqual(commands, [
    { type: 'select', mediaId: 'test.mp4' }, { type: 'play' },
    { type: 'pause', reason: 'user' }, { type: 'pause', reason: 'buffering' },
    { type: 'pause', reason: 'ended' }, { type: 'seek', positionSeconds: 12.5 },
    { type: 'ping', clientSentAtMs: 1000 }
  ]);
  console.log('PASS actual Fastify snapshots decoded by Haskell; Haskell commands accepted by actual JS validator');
} finally {
  if (socket !== undefined) {
    await incoming.return();
    socket.terminate();
  } else {
    // Connection setup failed before a socket was allocated.
  }
  for (const client of app.websocketServer.clients) {
    client.terminate();
  }
  await app.close();
  await rm(directory, { recursive: true, force: true });
}
