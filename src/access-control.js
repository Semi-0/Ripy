import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

const defaultSessionTtlMs = 12 * 60 * 60 * 1000;
const attemptWindowMs = 5 * 60 * 1000;
const maximumAttempts = 5;

function digest(value) {
  return createHash('sha256').update(value).digest();
}

function cookieValue(header, cookieName) {
  if (typeof header !== 'string') {
    return null;
  } else {
    for (const part of header.split(';')) {
      const separator = part.indexOf('=');
      if (separator >= 0 && part.slice(0, separator).trim() === cookieName) {
        return part.slice(separator + 1).trim();
      } else {
        // Continue looking for the session cookie.
      }
    }
    return null;
  }
}

function readPassword(name, environment) {
  const password = environment[name];
  if (password === undefined) {
    return undefined;
  } else if (typeof password !== 'string' || password.length < 8 || password.length > 1024) {
    throw new Error(`${name} must contain between 8 and 1024 characters.`);
  } else {
    return password;
  }
}

export function readAccessPassword(environment = process.env) {
  return readPassword('ROOM_PASSWORD', environment);
}

export function readAdminPassword(environment = process.env) {
  return readPassword('MEDIA_ADMIN_PASSWORD', environment);
}

export function createAccessControl({
  password,
  cookieName = 'ripy_session',
  now = Date.now,
  sessionTtlMs = defaultSessionTtlMs
} = {}) {
  if (password === undefined) {
    return { enabled: false };
  } else if (typeof password !== 'string' || password.length < 8 || password.length > 1024) {
    throw new Error('Access password must contain between 8 and 1024 characters.');
  } else if (!Number.isSafeInteger(sessionTtlMs) || sessionTtlMs <= 0) {
    throw new Error('Session lifetime must be a positive integer.');
  } else {
    // Continue with a fixed-length password digest.
  }

  const passwordDigest = digest(password);
  const sessions = new Map();
  const attempts = new Map();

  function prune() {
    const time = now();
    for (const [token, expiresAt] of sessions) {
      if (expiresAt <= time) {
        sessions.delete(token);
      } else {
        // This session remains active.
      }
    }
    for (const [address, attempt] of attempts) {
      if (attempt.resetAt <= time) {
        attempts.delete(address);
      } else {
        // This retry window remains active.
      }
    }
  }

  function authenticated(cookieHeader) {
    prune();
    const token = cookieValue(cookieHeader, cookieName);
    return token !== null && sessions.has(token);
  }

  function authenticate(candidate, address) {
    prune();
    const current = attempts.get(address);
    if (current !== undefined && current.count >= maximumAttempts) {
      return { status: 'limited', retryAfterSeconds: Math.max(1, Math.ceil((current.resetAt - now()) / 1000)) };
    } else {
      // Continue with constant-length password digest comparison.
    }
    const text = typeof candidate === 'string' && candidate.length <= 1024 ? candidate : '';
    if (!timingSafeEqual(digest(text), passwordDigest)) {
      const count = current === undefined ? 1 : current.count + 1;
      attempts.set(address, { count, resetAt: current?.resetAt ?? now() + attemptWindowMs });
      return { status: 'invalid' };
    } else {
      attempts.delete(address);
      return { status: 'authenticated' };
    }
  }

  function login(candidate, address) {
    const result = authenticate(candidate, address);
    if (result.status !== 'authenticated') {
      return result;
    } else {
      const token = randomBytes(32).toString('base64url');
      sessions.set(token, now() + sessionTtlMs);
      return { status: 'authenticated', token };
    }
  }

  function logout(cookieHeader) {
    const token = cookieValue(cookieHeader, cookieName);
    if (token !== null) {
      sessions.delete(token);
    } else {
      // There is no active token to remove.
    }
  }

  function sessionCookie(token, secure) {
    const attributes = [`${cookieName}=${token}`, `Max-Age=${Math.floor(sessionTtlMs / 1000)}`,
      'Path=/', 'HttpOnly', 'SameSite=Strict'];
    if (secure) {
      attributes.push('Secure');
    } else {
      // Loopback HTTP sessions cannot use a Secure cookie.
    }
    return attributes.join('; ');
  }

  function expiredCookie(secure) {
    const attributes = [`${cookieName}=`, 'Max-Age=0', 'Path=/', 'HttpOnly', 'SameSite=Strict'];
    if (secure) {
      attributes.push('Secure');
    } else {
      // Loopback HTTP sessions cannot use a Secure cookie.
    }
    return attributes.join('; ');
  }

  return {
    enabled: true, authenticated, authenticate, login, logout, sessionCookie, expiredCookie
  };
}
