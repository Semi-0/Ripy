import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { createMediaLibrary, MediaLibraryError, validateMediaFilename } from '../src/media-library.js';
import { buildServer } from '../src/server.js';

const validMp4 = Buffer.concat([
  Buffer.from([0, 0, 0, 24]),
  Buffer.from('ftypisom'),
  Buffer.alloc(32, 1)
]);

function basic(username, password) {
  return `Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`;
}

async function libraryFixture(t, maxUploadBytes = 1024) {
  const directory = await mkdtemp(join(tmpdir(), 'ripy-library-'));
  await writeFile(join(directory, '.ripy-upload-abandoned'), 'partial');
  const library = await createMediaLibrary({ directory, maxUploadBytes });
  t.after(() => rm(directory, { recursive: true, force: true }));
  return { directory, library };
}

async function serverFixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'ripy-media-server-'));
  const mediaDirectory = join(directory, 'media');
  const frontendDirectory = join(directory, 'frontend');
  await mkdir(mediaDirectory);
  await mkdir(frontendDirectory);
  await writeFile(join(frontendDirectory, 'index.html'), '<main>media fixture</main>');
  await writeFile(join(frontendDirectory, 'all.js'), '// fixture');
  const app = await buildServer({
    mediaDirectory,
    frontendDirectory,
    accessPassword: 'viewer password',
    adminPassword: 'administrator password',
    mediaUploadMaxBytes: 1024,
    ...options
  });
  await app.ready();
  t.after(async () => {
    for (const client of app.websocketServer.clients) {
      client.terminate();
    }
    await app.close();
    await rm(directory, { recursive: true, force: true });
  });
  return { app, mediaDirectory };
}

async function upload(app, filename, credentials = basic('viewer', 'viewer password'), body = validMp4) {
  return app.inject({
    method: 'PUT',
    url: `/api/media/${encodeURIComponent(filename)}`,
    headers: {
      authorization: credentials,
      'content-type': 'video/mp4',
      'content-length': String(body.length)
    },
    payload: body
  });
}

test('media library publishes validated uploads atomically and cleans temporary files', async (t) => {
  const { directory, library } = await libraryFixture(t);
  assert.deepEqual(await readdir(directory), []);
  const events = [];
  const unsubscribe = library.subscribe((event) => events.push(event));
  const movie = await library.upload({
    filename: 'new film.MP4',
    contentLength: validMp4.length,
    stream: Readable.from(validMp4)
  });
  unsubscribe();
  assert.equal(movie.id, 'new film.MP4');
  assert.deepEqual(library.snapshot().movies, [movie]);
  assert.deepEqual(events, [{ revision: 0 }, { revision: 1 }]);
  assert.deepEqual(await readFile(join(directory, movie.id)), validMp4);
  assert.deepEqual((await readdir(directory)).filter((name) => name.startsWith('.ripy-upload-')), []);

  await assert.rejects(() => library.upload({
    filename: movie.id,
    contentLength: validMp4.length,
    stream: Readable.from(validMp4)
  }), (error) => error instanceof MediaLibraryError && error.statusCode === 409);
  assert.equal(library.snapshot().revision, 1);
});

test('media library rejects unsafe names, invalid bytes, length mismatch and oversize uploads', async (t) => {
  const { directory, library } = await libraryFixture(t, validMp4.length);
  for (const filename of ['../film.mp4', 'folder\\film.mp4', '.ripy-upload-film.mp4', 'film.mov', 'bad\n.mp4']) {
    assert.throws(() => validateMediaFilename(filename), MediaLibraryError, filename);
  }
  await assert.rejects(() => library.upload({
    filename: 'invalid.mp4', contentLength: 8, stream: Readable.from(Buffer.alloc(8))
  }), (error) => error.code === 'INVALID_MEDIA');
  await assert.rejects(() => library.upload({
    filename: 'mismatch.mp4', contentLength: validMp4.length, stream: Readable.from(validMp4.subarray(0, -1))
  }), (error) => error.code === 'LENGTH_MISMATCH');
  await assert.rejects(() => library.upload({
    filename: 'large.mp4', contentLength: validMp4.length + 1, stream: Readable.from(validMp4)
  }), (error) => error.code === 'UPLOAD_TOO_LARGE');
  assert.deepEqual(await readdir(directory), []);
});

test('viewer can upload and select while only administrator can delete', async (t) => {
  const { app } = await serverFixture(t);
  const viewer = basic('viewer', 'viewer password');
  const admin = basic('admin', 'administrator password');
  const created = await upload(app, 'shared.mp4', viewer);
  assert.equal(created.statusCode, 201, created.body);
  assert.equal(created.json().movie.id, 'shared.mp4');
  assert.deepEqual((await app.inject({ url: '/api/movies', headers: { authorization: viewer } })).json(), {
    movies: [{ id: 'shared.mp4', title: 'shared', url: '/media/shared.mp4' }]
  });
  assert.equal((await app.inject({
    method: 'DELETE', url: '/api/media/shared.mp4', headers: { authorization: viewer }
  })).statusCode, 403);
  assert.equal((await app.inject({
    method: 'DELETE', url: '/api/media/shared.mp4', headers: { authorization: admin }
  })).statusCode, 204);
  assert.deepEqual((await app.inject({ url: '/api/movies', headers: { authorization: viewer } })).json(), { movies: [] });
});

test('administrator browser session grants deletion and logout removes it', async (t) => {
  const { app } = await serverFixture(t);
  const viewer = basic('viewer', 'viewer password');
  assert.equal((await upload(app, 'session.mp4', viewer)).statusCode, 201);
  const login = await app.inject({
    method: 'POST',
    url: '/api/media/admin/session',
    headers: {
      authorization: viewer,
      origin: 'http://localhost',
      host: 'localhost',
      'content-type': 'application/json'
    },
    payload: { password: 'administrator password' }
  });
  assert.equal(login.statusCode, 200, login.body);
  const cookie = login.headers['set-cookie'].split(';', 1)[0];
  const access = await app.inject({
    url: '/api/media/access', headers: { authorization: viewer, cookie }
  });
  assert.equal(access.json().uploadAllowed, true);
  assert.equal(access.json().deleteAllowed, true);
  assert.equal(access.json().adminEnabled, true);
  const logout = await app.inject({
    method: 'DELETE',
    url: '/api/media/admin/session',
    headers: { authorization: viewer, cookie }
  });
  assert.equal(logout.statusCode, 204);
  assert.equal((await app.inject({
    method: 'DELETE',
    url: '/api/media/session.mp4',
    headers: { authorization: viewer, cookie }
  })).statusCode, 403);
});

test('password-free uploads are loopback-only', async (t) => {
  const { app } = await serverFixture(t, { accessPassword: undefined });
  const local = await upload(app, 'local.mp4', undefined);
  assert.equal(local.statusCode, 201, local.body);
  const remote = await app.inject({
    method: 'PUT',
    url: '/api/media/remote.mp4',
    remoteAddress: '203.0.113.10',
    headers: { 'content-type': 'video/mp4', 'content-length': String(validMp4.length) },
    payload: validMp4
  });
  assert.equal(remote.statusCode, 403);
});

test('remote HTTP credentials and cross-origin uploads are rejected', async (t) => {
  const { app } = await serverFixture(t);
  const viewer = basic('viewer', 'viewer password');
  const insecure = await app.inject({
    method: 'PUT',
    url: '/api/media/insecure.mp4',
    remoteAddress: '203.0.113.10',
    headers: {
      authorization: viewer,
      'content-type': 'video/mp4',
      'content-length': String(validMp4.length)
    },
    payload: validMp4
  });
  assert.equal(insecure.statusCode, 401);

  const crossOrigin = await app.inject({
    method: 'PUT',
    url: '/api/media/cross-origin.mp4',
    headers: {
      authorization: viewer,
      host: 'localhost',
      origin: 'https://untrusted.example',
      'content-type': 'video/mp4',
      'content-length': String(validMp4.length)
    },
    payload: validMp4
  });
  assert.equal(crossOrigin.statusCode, 403);
});

test('deleting selected media clears the room once; deleting other media leaves revision unchanged', async (t) => {
  const { app } = await serverFixture(t);
  const viewer = basic('viewer', 'viewer password');
  const admin = basic('admin', 'administrator password');
  assert.equal((await upload(app, 'selected.mp4', viewer)).statusCode, 201);
  assert.equal((await upload(app, 'other.mp4', viewer)).statusCode, 201);
  const login = await app.inject({
    method: 'POST',
    url: '/auth/login',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      host: 'localhost',
      origin: 'http://localhost'
    },
    payload: new URLSearchParams({ password: 'viewer password' }).toString()
  });
  assert.equal(login.statusCode, 303);
  const viewerCookie = login.headers['set-cookie'].split(';', 1)[0];
  const messages = [];
  const socket = await app.injectWS('/room', { headers: { cookie: viewerCookie } }, {
    onInit(client) { client.on('message', (value) => messages.push(JSON.parse(value.toString()))); }
  });
  t.after(() => socket.terminate());
  await new Promise((resolve) => setTimeout(resolve, 10));
  socket.send(JSON.stringify({ type: 'select', mediaId: 'selected.mp4' }));
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(messages.at(-1).revision, 1);
  assert.equal((await app.inject({
    method: 'DELETE', url: '/api/media/other.mp4', headers: { authorization: admin }
  })).statusCode, 204);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(messages.at(-1).revision, 1);
  assert.equal((await app.inject({
    method: 'DELETE', url: '/api/media/selected.mp4', headers: { authorization: admin }
  })).statusCode, 204);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(messages.at(-1).revision, 2);
  assert.equal(messages.at(-1).mode, 'empty');
  assert.equal(messages.at(-1).mediaId, null);
});
