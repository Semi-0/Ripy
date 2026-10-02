import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createAccessControl, readAccessPassword, readAdminPassword } from '../src/access-control.js';
import { buildServer } from '../src/server.js';

async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'ripy-access-'));
  const mediaDirectory = join(directory, 'media');
  const frontendDirectory = join(directory, 'frontend');
  await mkdir(mediaDirectory);
  await mkdir(frontendDirectory);
  await writeFile(join(mediaDirectory, 'movie.mp4'), '0123456789');
  await writeFile(join(frontendDirectory, 'index.html'), '<main>private movie page</main>');
  await writeFile(join(frontendDirectory, 'all.js'), '// private compiled frontend');
  let now = 1000;
  const app = await buildServer({
    mediaDirectory,
    frontendDirectory,
    accessPassword: 'correct horse battery staple',
    accessSessionTtlMs: 10_000,
    now: () => now,
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
  return { app, advance(milliseconds) { now += milliseconds; } };
}

async function login(app, password) {
  return app.inject({
    method: 'POST',
    url: '/auth/login',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      host: 'ripy.test',
      origin: 'http://ripy.test'
    },
    payload: new URLSearchParams({ password }).toString()
  });
}

test('password configuration and secure cookie attributes are explicit', () => {
  assert.equal(readAccessPassword({}), undefined);
  assert.equal(readAccessPassword({ ROOM_PASSWORD: 'long enough' }), 'long enough');
  assert.equal(readAdminPassword({ MEDIA_ADMIN_PASSWORD: 'admin long enough' }), 'admin long enough');
  assert.throws(() => readAdminPassword({ MEDIA_ADMIN_PASSWORD: 'short' }), /between 8 and 1024/);
  assert.throws(() => readAccessPassword({ ROOM_PASSWORD: 'short' }), /between 8 and 1024/);
  const access = createAccessControl({ password: 'long enough', now: () => 0 });
  const result = access.login('long enough', 'viewer');
  assert.equal(result.status, 'authenticated');
  assert.match(access.sessionCookie(result.token, true),
    /^ripy_session=.+; Max-Age=43200; Path=\/; HttpOnly; SameSite=Strict; Secure$/);
});

test('loopback reverse proxy supplies trusted HTTPS for login and secure cookies', async (t) => {
  const { app } = await fixture(t, { trustProxy: ['127.0.0.1', '::1'] });
  const response = await app.inject({
    method: 'POST',
    url: '/auth/login',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      host: 'cinema.example',
      origin: 'https://cinema.example',
      'x-forwarded-proto': 'https'
    },
    payload: new URLSearchParams({ password: 'correct horse battery staple' }).toString()
  });
  assert.equal(response.statusCode, 303);
  assert.match(response.headers['set-cookie'], /; Secure$/);
});

test('password gate protects page, assets, APIs, media, ICE and room websocket', async (t) => {
  const { app } = await fixture(t);
  const page = await app.inject('/');
  assert.equal(page.statusCode, 303);
  assert.equal(page.headers.location, '/login');
  assert.equal((await app.inject('/login')).statusCode, 200);
  for (const url of ['/reflex/all.js', '/api/movies', '/api/voice/ice', '/media/movie.mp4']) {
    assert.equal((await app.inject(url)).statusCode, 401, url);
  }
  await assert.rejects(app.injectWS('/room'));

  const crossSite = await app.inject({
    method: 'POST',
    url: '/auth/login',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      host: 'ripy.test',
      origin: 'https://untrusted.example',
      'sec-fetch-site': 'cross-site'
    },
    payload: new URLSearchParams({ password: 'correct horse battery staple' }).toString()
  });
  assert.equal(crossSite.statusCode, 403);

  const rejected = await login(app, 'wrong password');
  assert.equal(rejected.statusCode, 401);
  assert.doesNotMatch(rejected.body, /correct horse/);
  const accepted = await login(app, 'correct horse battery staple');
  assert.equal(accepted.statusCode, 303);
  const setCookie = accepted.headers['set-cookie'];
  assert.match(setCookie, /HttpOnly; SameSite=Strict/);
  assert.doesNotMatch(setCookie, /Secure/);
  const cookie = setCookie.split(';', 1)[0];
  const headers = { cookie };
  assert.equal((await app.inject({ url: '/', headers })).statusCode, 200);
  assert.equal((await app.inject({ url: '/reflex/all.js', headers })).statusCode, 200);
  assert.equal((await app.inject({ url: '/api/movies', headers })).statusCode, 200);
  assert.equal((await app.inject({ url: '/api/voice/ice', headers })).statusCode, 200);
  const range = await app.inject({ url: '/media/movie.mp4', headers: { ...headers, range: 'bytes=2-5' } });
  assert.equal(range.statusCode, 206);
  assert.equal(range.body, '2345');
  const socket = await app.injectWS('/room', { headers });
  socket.terminate();
});

test('sessions expire, logout invalidates immediately and retries are bounded', async (t) => {
  const { app, advance } = await fixture(t);
  const accepted = await login(app, 'correct horse battery staple');
  const cookie = accepted.headers['set-cookie'].split(';', 1)[0];
  const logout = await app.inject({ method: 'POST', url: '/auth/logout', headers: { cookie } });
  assert.equal(logout.statusCode, 303);
  assert.match(logout.headers['set-cookie'], /Max-Age=0/);
  assert.equal((await app.inject({ url: '/api/movies', headers: { cookie } })).statusCode, 401);

  const second = await login(app, 'correct horse battery staple');
  const secondCookie = second.headers['set-cookie'].split(';', 1)[0];
  advance(10_001);
  assert.equal((await app.inject({ url: '/api/movies', headers: { cookie: secondCookie } })).statusCode, 401);

  for (let attempt = 0; attempt < 5; attempt += 1) {
    assert.equal((await login(app, 'incorrect')).statusCode, 401);
  }
  const limited = await login(app, 'correct horse battery staple');
  assert.equal(limited.statusCode, 429);
  assert.ok(Number(limited.headers['retry-after']) > 0);
});
