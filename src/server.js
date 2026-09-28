import Fastify from 'fastify';
import staticFiles from '@fastify/static';
import websocket from '@fastify/websocket';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';
import { readMediaCatalog } from './catalog.js';
import { decodeAndValidate, ProtocolError } from './protocol.js';
import { createEmptyRoom, transitionRoom } from './room.js';

const publicDirectory = fileURLToPath(new URL('../public/', import.meta.url));
export const defaultMediaDirectory = fileURLToPath(new URL('../media/', import.meta.url));

function send(socket, message) {
  if (socket.readyState === 1) {
    socket.send(JSON.stringify(message));
  } else {
    return;
  }
}

function handleMessage(socket, bytes, context) {
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

export async function buildServer({ mediaDirectory = defaultMediaDirectory, logger = false, now = Date.now } = {}) {
  const app = Fastify({ logger });
  const catalog = await readMediaCatalog(mediaDirectory);
  const context = { room: createEmptyRoom(randomUUID(), now()), catalog, clients: new Set(), now, log: app.log };

  await app.register(staticFiles, { root: mediaDirectory, serve: false, acceptRanges: true });
  await app.register(staticFiles, { root: publicDirectory, prefix: '/assets/', decorateReply: false });
  const candidateDirectory = fileURLToPath(new URL('../frontend-dist/', import.meta.url));
  if (existsSync(candidateDirectory)) {
    await app.register(staticFiles, { root: candidateDirectory, prefix: '/reflex/', decorateReply: false });
  } else {
    // The working JavaScript frontend remains available until a candidate is built.
  }
  await app.register(websocket, { options: { maxPayload: 4096 } });

  app.get('/', async (_request, reply) => reply.sendFile('index.html', publicDirectory));
  app.get('/api/movies', async () => ({ movies: [...catalog.values()] }));
  app.get('/media/:filename', async (request, reply) => {
    if (!catalog.has(request.params.filename)) {
      return reply.code(404).send({ error: 'Movie is unavailable.' });
    } else {
      return reply.sendFile(request.params.filename);
    }
  });

  app.get('/room', { websocket: true }, (socket, request) => {
    // Keep this unauthenticated local demo unavailable to cross-origin webpages.
    const origin = request.headers.origin;
    const expectedOrigin = `${request.protocol}://${request.headers.host}`;
    if (origin !== undefined && origin !== expectedOrigin) {
      socket.close(1008, 'Cross-origin connections are not allowed.');
    } else {
      context.clients.add(socket);
      socket.on('message', (bytes) => handleMessage(socket, bytes, context));
      socket.on('close', () => context.clients.delete(socket));
      socket.on('error', (error) => app.log.warn(error));
      send(socket, context.room);
    }
  });
  return app;
}
