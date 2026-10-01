export const Anonymous = 0;
export const Viewer = 1;
export const Administrator = 2;

export function isLoopback(address) {
  if (typeof address !== 'string') {
    return false;
  } else {
    return address === '127.0.0.1' || address === '::1' || address.startsWith('127.') ||
      address.startsWith('::ffff:127.');
  }
}

function basicCredentials(header) {
  if (typeof header !== 'string' || !header.startsWith('Basic ')) {
    return null;
  } else {
    try {
      const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
      const separator = decoded.indexOf(':');
      if (separator < 0) {
        return null;
      } else {
        return { username: decoded.slice(0, separator), password: decoded.slice(separator + 1) };
      }
    } catch (_error) {
      return null;
    }
  }
}

export function secureOrLoopback(request) {
  if (request.protocol === 'https') {
    return true;
  } else {
    return isLoopback(request.ip);
  }
}

export function createRequestAuthorizer({ viewerAccess, adminAccess }) {
  function role(request) {
    const cookieHeader = request.headers.cookie;
    if (adminAccess.enabled && adminAccess.authenticated(cookieHeader)) {
      return Administrator;
    } else if (viewerAccess.enabled && viewerAccess.authenticated(cookieHeader)) {
      return Viewer;
    } else {
      const credentials = basicCredentials(request.headers.authorization);
      if (credentials === null || !secureOrLoopback(request)) {
        return Anonymous;
      } else if (credentials.username === 'admin' && adminAccess.enabled) {
        const result = adminAccess.authenticate(credentials.password, request.ip);
        if (result.status === 'authenticated') {
          return Administrator;
        } else {
          return Anonymous;
        }
      } else if (credentials.username === 'viewer' && viewerAccess.enabled) {
        const result = viewerAccess.authenticate(credentials.password, request.ip);
        if (result.status === 'authenticated') {
          return Viewer;
        } else {
          return Anonymous;
        }
      } else {
        return Anonymous;
      }
    }
  }

  function canRead(request) {
    if (!viewerAccess.enabled) {
      return true;
    } else {
      return role(request) >= Viewer;
    }
  }

  function canUpload(request) {
    const resolved = role(request);
    if (resolved >= Viewer) {
      return true;
    } else if (!viewerAccess.enabled) {
      return isLoopback(request.ip);
    } else {
      return false;
    }
  }

  function canDelete(request) {
    return role(request) >= Administrator;
  }

  function requireUpload(request, reply) {
    if (canUpload(request)) {
      return true;
    } else if (role(request) >= Viewer || !viewerAccess.enabled) {
      reply.code(403).send({ error: 'Upload is unavailable for this viewer.' });
      return false;
    } else {
      reply.code(401).header('www-authenticate', 'Basic realm="Ripy"')
        .send({ error: 'Authentication required.' });
      return false;
    }
  }

  function requireAdmin(request, reply) {
    if (canDelete(request)) {
      return true;
    } else if (canRead(request)) {
      reply.code(403).send({ error: 'Administrator authorization required.' });
      return false;
    } else {
      reply.code(401).header('www-authenticate', 'Basic realm="Ripy admin"')
        .send({ error: 'Authentication required.' });
      return false;
    }
  }

  return { role, canRead, canUpload, canDelete, requireUpload, requireAdmin };
}
