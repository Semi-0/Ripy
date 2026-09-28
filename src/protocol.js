export class ProtocolError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function rejectUnless(valid, message) {
  if (!valid) {
    throw new ProtocolError('INVALID_MESSAGE', message);
  } else {
    return;
  }
}

function exactFields(message, fields) {
  rejectUnless(Object.keys(message).every((key) => fields.includes(key)), 'Unexpected message fields.');
}

export function decodeAndValidate(bytes) {
  let message;
  try {
    message = JSON.parse(bytes.toString());
  } catch {
    throw new ProtocolError('INVALID_MESSAGE', 'Expected a JSON object.');
  }
  rejectUnless(message !== null && typeof message === 'object' && !Array.isArray(message), 'Expected a JSON object.');
  switch (message.type) {
    case 'select':
      exactFields(message, ['type', 'mediaId']);
      rejectUnless(typeof message.mediaId === 'string' && message.mediaId.length > 0, 'mediaId must be a nonempty string.');
      return message;
    case 'play':
      exactFields(message, ['type']);
      return message;
    case 'pause':
      exactFields(message, ['type', 'reason']);
      switch (message.reason) {
        case undefined: return { type: 'pause', reason: 'user' };
        case 'user':
        case 'buffering':
        case 'ended': return message;
        default: throw new ProtocolError('INVALID_MESSAGE', 'Invalid pause reason.');
      }
    case 'seek':
      exactFields(message, ['type', 'positionSeconds']);
      rejectUnless(Number.isFinite(message.positionSeconds) && message.positionSeconds >= 0, 'Seek position must be finite and nonnegative.');
      return message;
    case 'ping':
      exactFields(message, ['type', 'clientSentAtMs']);
      rejectUnless(Number.isFinite(message.clientSentAtMs), 'Ping timestamp must be finite.');
      return message;
    default: throw new ProtocolError('INVALID_MESSAGE', 'Unsupported message type.');
  }
}
