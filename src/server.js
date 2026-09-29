import Fastify from 'fastify';
import staticFiles from '@fastify/static';
import websocket from '@fastify/websocket';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
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
  return origin === undefined || origin === expectedOrigin;
}

export async function buildServer({
  mediaDirectory = defaultMediaDirectory,
  frontendDirectory = defaultFrontendDirectory,
  logger = false,
  now = Date.now,
  voiceIceConfiguration = readVoiceIceConfiguration()
} = {}) {
  const app = Fastify({ logger });
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
