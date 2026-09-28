import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, mkdir, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildServer } from '../src/server.js';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'cinema-test-'));
  const mediaDirectory = join(directory, 'media');
  await mkdir(mediaDirectory);
  await writeFile(join(mediaDirectory, 'test clip.mp4'), '0123456789abcdef');
  await writeFile(join(directory, 'secret.mp4'), 'secret');
  await writeFile(join(mediaDirectory, 'notes.txt'), 'not a movie');
  await symlink(join(directory, 'secret.mp4'), join(mediaDirectory, 'link.mp4'));
  await mkdir(join(mediaDirectory, 'directory.mp4'));
  let now = 1000;
  const app = await buildServer({ mediaDirectory, now: () => now });
  await app.ready();
  t.after(async () => {
    for (const client of app.websocketServer.clients) {
      client.terminate();
    }
    await app.close();
    await rm(directory, { recursive: true, force: true });
  });
  return { app, setTime(value) { now = value; } };
}

// Queue all received messages so initial snapshots and broadcasts are never lost.
async function peer(app, t) {
  const messages = [];
  let waiting = null;
  function receive(bytes) {
    const message = JSON.parse(bytes.toString());
    if (waiting === null) {
      messages.push(message);
    } else {
      const resolve = waiting;
      waiting = null;
      resolve(message);
    }
  }
  const socket = await app.injectWS('/room', {}, {
    onInit(client) { client.on('message', receive); }
  });
  t.after(() => socket.terminate());
  return {
    socket,
    send(message) { socket.send(JSON.stringify(message)); },
    next() {
      if (messages.length > 0) {
        return Promise.resolve(messages.shift());
      } else {
        return new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('Timed out waiting for room response')), 2000);
          waiting = (message) => { clearTimeout(timer); resolve(message); };
        });
      }
    }
  };
}

test('catalog and HTTP serving support ranges and exclude unsafe paths', async (t) => {
  const { app } = await fixture(t);
  const catalog = await app.inject('/api/movies');
  assert.deepEqual(catalog.json().movies, [{ id: 'test clip.mp4', title: 'test clip', url: '/media/test%20clip.mp4' }]);
  assert.equal((await app.inject('/')).statusCode, 200);
  const range = await app.inject({ url: '/media/test%20clip.mp4', headers: { range: 'bytes=2-5' } });
  assert.equal(range.statusCode, 206);
  assert.equal(range.body, '2345');
  assert.equal(range.headers['content-range'], 'bytes 2-5/16');
  assert.match(range.headers['content-type'], /video\/mp4/);
  assert.equal((await app.inject({ url: '/media/test%20clip.mp4', headers: { range: 'bytes=100-200' } })).statusCode, 416);
  for (const url of ['/media/missing.mp4', '/media/link.mp4', '/media/notes.txt', '/media/directory.mp4',
    '/media/%2e%2e%2fsecret.mp4', '/media/%2e%2e/secret.mp4']) {
    assert.equal((await app.inject(url)).statusCode, 404, url);
  }
  const traversal = await app.inject('/assets/%2e%2e%2fsrc/server.js');
  assert.ok([403, 404].includes(traversal.statusCode));
});

test('two peers share ordered state; late join and reconnect catch up', async (t) => {
  const { app, setTime } = await fixture(t);
  const a = await peer(app, t);
  const initial = await a.next();
  assert.equal(initial.mode, 'empty');
  a.send({ type: 'select', mediaId: 'test clip.mp4' });
  assert.equal((await a.next()).revision, 1);
  a.send({ type: 'play' });
  assert.equal((await a.next()).mode, 'playing');
  setTime(5000);
  const b = await peer(app, t);
  const joined = await b.next();
  assert.equal(joined.revision, 2);
  assert.equal(joined.anchorServerTimeMs, 1000);
  b.send({ type: 'pause', reason: 'buffering' });
  const paused = await a.next();
  assert.deepEqual(await b.next(), paused);
  assert.equal(paused.positionSeconds, 4);
  assert.equal(paused.pauseReason, 'buffering');
  b.socket.terminate();
  a.send({ type: 'seek', positionSeconds: 12 });
  const sought = await a.next();
  const reconnected = await peer(app, t);
  assert.deepEqual(await reconnected.next(), sought);
});

test('invalid messages return errors without advancing state, ping is private', async (t) => {
  const { app } = await fixture(t);
  const a = await peer(app, t);
  const initial = await a.next();
  for (const [command, code] of [[{ type: 'play' }, 'NO_MEDIA'],
    [{ type: 'select', mediaId: '../secret.mp4' }, 'UNKNOWN_MEDIA'],
    [{ type: 'seek', positionSeconds: -1 }, 'INVALID_MESSAGE']]) {
    a.send(command);
    assert.equal((await a.next()).code, code);
  }
  a.socket.send('{');
  assert.equal((await a.next()).code, 'INVALID_MESSAGE');
  a.send({ type: 'ping', clientSentAtMs: 200 });
  assert.deepEqual(await a.next(), { type: 'pong', clientSentAtMs: 200, serverTimeMs: 1000 });
  const b = await peer(app, t);
  assert.deepEqual(await b.next(), initial);
  a.send({ type: 'ping', clientSentAtMs: 300 });
  assert.equal((await a.next()).type, 'pong');
  a.send({ type: 'select', mediaId: 'test clip.mp4' });
  assert.equal((await b.next()).revision, 1, 'peer received state, not another viewer’s pong');
});

test('server restart creates a new epoch', async (t) => {
  const first = await fixture(t);
  const second = await fixture(t);
  const a = await peer(first.app, t);
  const b = await peer(second.app, t);
  assert.notEqual((await a.next()).epoch, (await b.next()).epoch);
});

test('empty catalog is supported', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'cinema-empty-'));
  const app = await buildServer({ mediaDirectory: directory });
  t.after(async () => { await app.close(); await rm(directory, { recursive: true }); });
  assert.deepEqual((await app.inject('/api/movies')).json(), { movies: [] });
});
