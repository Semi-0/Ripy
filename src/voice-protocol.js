const MAX_SDP_LENGTH = 32 * 1024;
const MAX_CANDIDATE_LENGTH = 4 * 1024;

export class VoiceProtocolError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'VoiceProtocolError';
    this.code = code;
  }
}

function objectWithKeys(value, allowed) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new VoiceProtocolError('INVALID_MESSAGE', 'Voice message must be an object.');
  } else {
    const unexpected = Object.keys(value).filter((key) => !allowed.includes(key));
    if (unexpected.length > 0) {
      throw new VoiceProtocolError('INVALID_MESSAGE', 'Voice message contains unexpected fields.');
    } else {
      return value;
    }
  }
}

function boundedText(value, limit, field) {
  if (typeof value !== 'string' || value.length === 0 || value.length > limit) {
    throw new VoiceProtocolError('INVALID_MESSAGE', `${field} is invalid.`);
  } else {
    return value;
  }
}

function optionalText(value, limit, field) {
  if (value === null || value === undefined) {
    return null;
  } else {
    return boundedText(value, limit, field);
  }
}

function optionalIndex(value) {
  if (value === null || value === undefined) {
    return null;
  } else if (Number.isInteger(value) && value >= 0 && value <= 65535) {
    return value;
  } else {
    throw new VoiceProtocolError('INVALID_MESSAGE', 'sdpMLineIndex is invalid.');
  }
}

export function decodeVoiceMessage(bytes) {
  let parsed;
  try {
    parsed = JSON.parse(bytes.toString());
  } catch (_error) {
    throw new VoiceProtocolError('INVALID_MESSAGE', 'Voice message is not valid JSON.');
  }
  const message = objectWithKeys(parsed,
    ['type', 'sdp', 'candidate', 'sdpMid', 'sdpMLineIndex']);
  switch (message.type) {
    case 'offer':
    case 'answer':
      objectWithKeys(message, ['type', 'sdp']);
      return { type: message.type, sdp: boundedText(message.sdp, MAX_SDP_LENGTH, 'sdp') };
    case 'ice':
      objectWithKeys(message, ['type', 'candidate', 'sdpMid', 'sdpMLineIndex']);
      return {
        type: 'ice',
        candidate: boundedText(message.candidate, MAX_CANDIDATE_LENGTH, 'candidate'),
        sdpMid: optionalText(message.sdpMid, 256, 'sdpMid'),
        sdpMLineIndex: optionalIndex(message.sdpMLineIndex)
      };
    case 'leave':
      objectWithKeys(message, ['type']);
      return { type: 'leave' };
    default:
      throw new VoiceProtocolError('INVALID_MESSAGE', 'Unknown voice message type.');
  }
}
