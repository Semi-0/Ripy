import { MediaLibraryError } from './media-library.js';
import { secureOrLoopback } from './media-authorization.js';

function sendMediaError(reply, error) {
  if (error instanceof MediaLibraryError) {
    return reply.code(error.statusCode).send({ code: error.code, error: error.message });
  } else {
    throw error;
  }
}

function contentLength(request) {
  const raw = request.headers['content-length'];
  if (typeof raw !== 'string' || !/^\d+$/.test(raw)) {
    throw new MediaLibraryError('INVALID_LENGTH', 'Content-Length is required.', 411);
  } else {
    const value = Number(raw);
    if (!Number.isSafeInteger(value) || value <= 0) {
      throw new MediaLibraryError('INVALID_LENGTH', 'Content-Length must be a positive integer.', 411);
    } else {
      return value;
    }
  }
}

function supportedContentType(request) {
  const header = request.headers['content-type'];
  if (typeof header !== 'string') {
    return false;
  } else {
    const contentType = header.split(';', 1)[0].trim().toLowerCase();
    return contentType === 'video/mp4' || contentType === 'application/octet-stream';
  }
}

export function installMediaManagement(app, {
  library,
  authorizer,
  adminAccess,
  secureCookies,
  sameOrigin,
  mediaDeleted
}) {
  for (const mediaType of ['video/mp4', 'application/octet-stream']) {
    app.addContentTypeParser(mediaType, (request, payload, done) => done(null, payload));
  }

  app.get('/api/media/access', async (request, reply) => {
    reply.header('cache-control', 'no-store');
    return {
      uploadAllowed: authorizer.canUpload(request),
      deleteAllowed: authorizer.canDelete(request),
      adminEnabled: adminAccess.enabled,
      maxUploadBytes: library.maxUploadBytes
    };
  });

  app.put('/api/media/:filename', async (request, reply) => {
    if (!authorizer.requireUpload(request, reply)) {
      return reply;
    } else if (!sameOrigin(request)) {
      return reply.code(403).send({ error: 'Cross-origin upload is not allowed.' });
    } else if (!supportedContentType(request)) {
      return reply.code(415).send({ error: 'Content-Type must be video/mp4 or application/octet-stream.' });
    } else {
      try {
        const movie = await library.upload({
          filename: request.params.filename,
          contentLength: contentLength(request),
          stream: request.body
        });
        return reply.code(201).send({ movie });
      } catch (error) {
        return sendMediaError(reply, error);
      }
    }
  });

  app.delete('/api/media/:filename', async (request, reply) => {
    if (!authorizer.requireAdmin(request, reply)) {
      return reply;
    } else if (!sameOrigin(request)) {
      return reply.code(403).send({ error: 'Cross-origin deletion is not allowed.' });
    } else {
      try {
        const mediaId = await library.remove(request.params.filename);
        mediaDeleted(mediaId);
        return reply.code(204).send();
      } catch (error) {
        return sendMediaError(reply, error);
      }
    }
  });

  app.get('/api/media/events', async (request, reply) => {
    if (!authorizer.canRead(request)) {
      return reply.code(401).send({ error: 'Authentication required.' });
    } else {
      reply.hijack();
      reply.raw.writeHead(200, {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-store',
        connection: 'keep-alive',
        'x-content-type-options': 'nosniff'
      });
      const unsubscribe = library.subscribe((event) => {
        reply.raw.write(`data: ${JSON.stringify(event)}\n\n`);
      });
      request.raw.on('close', unsubscribe);
      return reply;
    }
  });

  app.post('/api/media/admin/session', async (request, reply) => {
    if (!adminAccess.enabled) {
      return reply.code(404).send({ error: 'Administrator access is not configured.' });
    } else if (!sameOrigin(request)) {
      return reply.code(403).send({ error: 'Cross-origin administrator login is not allowed.' });
    } else if (!secureOrLoopback(request)) {
      return reply.code(403).send({ error: 'Administrator login requires HTTPS or loopback.' });
    } else {
      let password;
      if (request.body === null || request.body === undefined) {
        password = undefined;
      } else {
        password = request.body.password;
      }
      const result = adminAccess.login(password, request.ip);
      switch (result.status) {
        case 'authenticated':
          return reply.header('set-cookie', adminAccess.sessionCookie(result.token, secureCookies))
            .header('cache-control', 'no-store').send({ authenticated: true });
        case 'limited':
          return reply.code(429).header('retry-after', String(result.retryAfterSeconds))
            .send({ error: 'Too many administrator login attempts.' });
        case 'invalid':
          return reply.code(401).send({ error: 'Administrator password is incorrect.' });
        default:
          throw new Error('Unsupported administrator access result.');
      }
    }
  });

  app.delete('/api/media/admin/session', async (request, reply) => {
    if (!authorizer.requireAdmin(request, reply)) {
      return reply;
    } else if (!sameOrigin(request)) {
      return reply.code(403).send({ error: 'Cross-origin administrator logout is not allowed.' });
    } else {
      adminAccess.logout(request.headers.cookie);
      return reply.header('set-cookie', adminAccess.expiredCookie(secureCookies))
        .header('cache-control', 'no-store').code(204).send();
    }
  });
}
