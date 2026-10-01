import { positionAt } from './timeline.js';
import { ProtocolError } from './protocol.js';

export function createEmptyRoom(epoch, now) {
  return {
    type: 'state', epoch, revision: 0, mediaId: null, mode: 'empty',
    positionSeconds: 0, anchorServerTimeMs: now, pauseReason: null
  };
}

export function clearDeletedMedia(state, mediaId, now) {
  if (state.mediaId !== mediaId) {
    return state;
  } else {
    return {
      ...state, revision: state.revision + 1, mediaId: null, mode: 'empty',
      positionSeconds: 0, anchorServerTimeMs: now, pauseReason: null
    };
  }
}

// Caller validates wire messages. This function owns only room transitions.
export function transitionRoom(state, command, now, catalog) {
  const next = {
    ...state, revision: state.revision + 1,
    positionSeconds: positionAt(state, now), anchorServerTimeMs: now
  };
  if (command.type === 'select') {
    if (!catalog.has(command.mediaId)) {
      throw new ProtocolError('UNKNOWN_MEDIA', 'Movie is unavailable.');
    } else {
      return { ...next, mediaId: command.mediaId, mode: 'paused', positionSeconds: 0, pauseReason: 'selected' };
    }
  } else {
    if (state.mode === 'empty') {
      throw new ProtocolError('NO_MEDIA', 'Select a movie first.');
    } else {
      switch (command.type) {
        case 'play': return { ...next, mode: 'playing', pauseReason: null };
        case 'pause': return { ...next, mode: 'paused', pauseReason: command.reason };
        case 'seek': return { ...next, positionSeconds: command.positionSeconds };
        default: throw new ProtocolError('INVALID_MESSAGE', 'Unsupported room command.');
      }
    }
  }
}
