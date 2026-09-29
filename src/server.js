import Fastify from 'fastify';
import staticFiles from '@fastify/static';
import websocket from '@fastify/websocket';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { createAccessControl } from './access-control.js';
import { readMediaCatalog } from './catalog.js';
import { decodeAndValidate, ProtocolError } from './protocol.js';
import { createEmptyRoom, transitionRoom } from './room.js';
import { createVoiceIceResponse, readVoiceIceConfiguration } from './voice-ice.js';
import { createVoiceRoom } from './voice-room.js';

const publicDirectory = fileURLToPath(new URL('../public/', import.meta.url));
export const defaultMediaDirectory = fileURLToPath(new URL('../media/', import.meta.url));
const defaultFrontendDirectory = fileURLToPath(new URL('../frontend-dist/', import.meta.url));

function send(socket, message) {
  if (socket.readyState === 1) {
    socket.send(JSON.stringify(message));
  } else {
    return;
  }
}

function handleMessage(socket, bytes, context) {
  if (bytes.length > 4096) {
    send(socket, { type: 'error', code: 'INVALID_MESSAGE', message: 'Message exceeds 4 KiB.' });
    return;
  } else {
    // Continue with the original room protocol limit.
  }
  try {
    const command = decodeAndValidate(bytes);
    switch (command.type) {
      case 'ping':
        send(socket, { type: 'pong', clientSentAtMs: command.clientSentAtMs, serverTimeMs: context.now() });
        break;
      default: {
        const next = transitionRoom(context.room, command, context.now(), context.catalog);
        context.room = next;
        for (const client of context.clients) {
          send(client, next);
        }
        break;
      }
    }
  } catch (error) {
    if (error instanceof ProtocolError) {
      send(socket, { type: 'error', code: error.code, message: error.message });
    } else {
      context.log.error(error);
      send(socket, { type: 'error', code: 'INTERNAL_ERROR', message: 'Unable to process command.' });
    }
  }
}

function sameOrigin(request) {
  const origin = request.headers.origin;
  const expectedOrigin = `${request.protocol}://${request.headers.host}`;
  if (origin === undefined || origin === expectedOrigin) {
    return true;
  } else if (origin === 'null' && request.headers['sec-fetch-site'] === 'same-origin') {
    return true;
  } else {
    return false;
  }
}

function loginPage(message = '') {
  const feedback = message === '' ? '' : `<p role="alert">${message}</p>`;
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ripy / Private screening</title><style>:root{color-scheme:dark;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:#0b0b0b;color:#e5e5e5}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px}main{width:min(440px,100%);border-top:1px solid #777;padding-top:18px}small,p{color:#aaa}h1{font-size:30px;font-weight:500}label{display:grid;gap:8px;font-size:12px}input,button{width:100%;border:1px solid #555;border-radius:0;background:#111;color:inherit;padding:12px;font:inherit}button{margin-top:14px;background:#e5e5e5;color:#111;cursor:pointer}p[role=alert]{border-left:2px solid #fff;padding-left:12px;color:#fff}</style></head><body><main><small>PRIVATE SCREENING / AUTHORIZATION</small><h1>Ripy<span aria-hidden="true">_</span></h1><p>Enter the shared room password to continue.</p>${feedback}<form method="post" action="/auth/login"><label for="password">Room password<input id="password" name="password" type="password" autocomplete="current-password" required autofocus maxlength="1024"></label><button type="submit">Enter screening</button></form></main></body></html>`;
}

function loginHeaders(reply) {
  return reply
    .header('cache-control', 'no-store')
    .header('content-security-policy', "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
    .header('referrer-policy', 'no-referrer')
    .header('x-frame-options', 'DENY');
}

export async function buildServer({
  mediaDirectory = defaultMediaDirectory,
  frontendDirectory = defaultFrontendDirectory,
  logger = false,
  https = undefined,
  now = Date.now,
  accessPassword = undefined,
  accessSessionTtlMs = undefined,
  voiceIceConfiguration = readVoiceIceConfiguration()
} = {}) {
  let app;
  if (https === undefined) {
    app = Fastify({ logger });
  } else {
    app = Fastify({ logger, https });
  }
  const access = createAccessControl({ password: accessPassword, now, sessionTtlMs: accessSessionTtlMs });
  const secureCookies = https !== undefined;
  if (access.enabled) {
    app.addContentTypeParser('application/x-www-form-urlencoded',
      { parseAs: 'string', bodyLimit: 2048 }, (_request, body, done) => {
        try {
          const values = new URLSearchParams(body);
          done(null, { password: values.get('password') });
        } catch (error) {
          done(error);
        }
      });
    app.addHook('onRequest', async (request, reply) => {
      const path = new URL(request.raw.url, 'http://ripy.invalid').pathname;
      const publicRequest = path === '/login' || path === '/auth/login' || path.startsWith('/assets/');
      if (publicRequest || access.authenticated(request.headers.cookie)) {
        return;
      } else if (path === '/' && request.method === 'GET') {
        return reply.code(303).header('location', '/login').send();
      } else {
        return reply.code(401).header('cache-control', 'no-store').send({ error: 'Authentication required.' });
      }
    });
  } else {
    // Preserve the password-free localhost prototype unless ROOM_PASSWORD is configured.
  }
  const catalog = await readMediaCatalog(mediaDirectory);
  const context = { room: createEmptyRoom(randomUUID(), now()), catalog, clients: new Set(), now, log: app.log };

  await app.register(staticFiles, { root: mediaDirectory, serve: false, acceptRanges: true });
  await app.register(staticFiles, { root: publicDirectory, prefix: '/assets/', decorateReply: false });
  const hasFrontend = existsSync(join(frontendDirectory, 'index.html')) && existsSync(join(frontendDirectory, 'all.js'));
  if (hasFrontend) {
    await app.register(staticFiles, { root: frontendDirectory, prefix: '/reflex/', decorateReply: false });
  } else {
    app.log.warn('Install a verified Reflex artifact before opening the movie page. See frontend/README.md.');
  }
  const voiceRoom = createVoiceRoom({ log: app.log });
  await app.register(websocket, { options: { maxPayload: 64 * 1024 } });

  app.get('/login', async (request, reply) => {
    if (!access.enabled) {
      return reply.code(303).header('location', '/').send();
    } else if (access.authenticated(request.headers.cookie)) {
      return reply.code(303).header('location', '/').send();
    } else {
      return loginHeaders(reply).type('text/html; charset=utf-8').send(loginPage());
    }
  });
  app.post('/auth/login', { bodyLimit: 2048 }, async (request, reply) => {
    if (!access.enabled) {
      return reply.code(404).send({ error: 'Password access is not configured.' });
    } else if (!sameOrigin(request)) {
      return reply.code(403).send({ error: 'Cross-origin login is not allowed.' });
    } else {
      const result = access.login(request.body?.password, request.ip);
      switch (result.status) {
        case 'authenticated':
          return loginHeaders(reply)
            .header('set-cookie', access.sessionCookie(result.token, secureCookies))
            .code(303).header('location', '/').send();
        case 'limited':
          return loginHeaders(reply).header('retry-after', String(result.retryAfterSeconds))
            .code(429).type('text/html; charset=utf-8')
            .send(loginPage('Too many attempts. Wait five minutes and try again.'));
        case 'invalid':
          return loginHeaders(reply).code(401).type('text/html; charset=utf-8')
            .send(loginPage('The room password is incorrect.'));
        default:
          throw new Error('Unsupported access result.');
      }
    }
  });
  app.post('/auth/logout', async (request, reply) => {
    if (!access.enabled) {
      return reply.code(404).send({ error: 'Password access is not configured.' });
    } else {
      access.logout(request.headers.cookie);
      return reply.header('set-cookie', access.expiredCookie(secureCookies))
        .code(303).header('location', '/login').send();
    }
  });

  app.get('/', async (_request, reply) => {
    if (hasFrontend) {
      return reply.sendFile('index.html', frontendDirectory);
    } else {
      return reply.code(503).type('text/plain').send('Reflex frontend is not installed. Follow frontend/README.md to install a successful CI artifact, then restart this server.');
    }
  });
  app.get('/api/movies', async () => ({ movies: [...catalog.values()] }));
  app.get('/api/voice/ice', async (_request, reply) => {
    reply.header('cache-control', 'no-store');
    return createVoiceIceResponse(voiceIceConfiguration, now);
  });
  app.get('/media/:filename', async (request, reply) => {
    if (!catalog.has(request.params.filename)) {
      return reply.code(404).send({ error: 'Movie is unavailable.' });
    } else {
      return reply.sendFile(request.params.filename);
    }
  });

  app.get('/room', { websocket: true }, (socket, request) => {
    // Keep this unauthenticated local demo unavailable to cross-origin webpages.
    if (!sameOrigin(request)) {
      socket.close(1008, 'Cross-origin connections are not allowed.');
    } else {
      context.clients.add(socket);
      socket.on('message', (bytes) => handleMessage(socket, bytes, context));
      socket.on('close', () => context.clients.delete(socket));
      socket.on('error', (error) => app.log.warn(error));
      send(socket, context.room);
    }
  });
  app.get('/voice', { websocket: true }, (socket, request) => {
    if (!sameOrigin(request)) {
      socket.close(1008, 'Cross-origin connections are not allowed.');
    } else if (voiceRoom.join(socket)) {
      socket.on('message', (bytes) => voiceRoom.receive(socket, bytes));
      socket.on('close', () => voiceRoom.leave(socket));
      socket.on('error', (error) => app.log.warn(error));
    } else {
      // join already reported and closed a full room.
    }
  });
  return app;
}
