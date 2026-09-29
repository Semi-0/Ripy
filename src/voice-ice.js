import { createHmac } from 'node:crypto';

function urlList(value) {
  if (value === undefined || value.trim() === '') {
    return [];
  } else {
    return value.split(',').map((entry) => entry.trim()).filter((entry) => entry !== '');
  }
}

function positiveInteger(value, fallback) {
  if (value === undefined || value === '') {
    return fallback;
  } else {
    const parsed = Number(value);
    if (Number.isInteger(parsed) && parsed > 0) {
      return parsed;
    } else {
      throw new Error('VOICE_TURN_TTL_SECONDS must be a positive integer.');
    }
  }
}

export function readVoiceIceConfiguration(environment = process.env) {
  const stunUrls = urlList(environment.VOICE_STUN_URLS);
  const turnUrls = urlList(environment.VOICE_TURN_URLS);
  const turnSharedSecret = environment.VOICE_TURN_SHARED_SECRET ?? '';
  const ttlSeconds = positiveInteger(environment.VOICE_TURN_TTL_SECONDS, 3600);
  if ((turnUrls.length === 0) !== (turnSharedSecret === '')) {
    throw new Error('VOICE_TURN_URLS and VOICE_TURN_SHARED_SECRET must be configured together.');
  } else {
    return { stunUrls, turnUrls, turnSharedSecret, ttlSeconds };
  }
}

export function createVoiceIceResponse(configuration, now = Date.now) {
  const iceServers = [];
  if (configuration.stunUrls.length > 0) {
    iceServers.push({ urls: configuration.stunUrls });
  } else {
    // Host candidates still support localhost and many LAN calls.
  }
  if (configuration.turnUrls.length === 0) {
    return { iceServers, expiresAt: null };
  } else {
    const expiresAtSeconds = Math.floor(now() / 1000) + configuration.ttlSeconds;
    const username = `${expiresAtSeconds}:ripy`;
    const credential = createHmac('sha1', configuration.turnSharedSecret)
      .update(username).digest('base64');
    iceServers.push({ urls: configuration.turnUrls, username, credential });
    return { iceServers, expiresAt: expiresAtSeconds * 1000 };
  }
}
