import { decodeVoiceMessage, VoiceProtocolError } from './voice-protocol.js';

function send(socket, message) {
  if (socket.readyState === 1) {
    socket.send(JSON.stringify(message));
  } else {
    return;
  }
}

export function createVoiceRoom({ log = { warn() {} } } = {}) {
  const peers = [];
  const roles = new Map();

  function other(socket) {
    return peers.find((peer) => peer !== socket) ?? null;
  }

  function pair() {
    if (peers.length === 2) {
      roles.set(peers[0], 'offerer');
      roles.set(peers[1], 'answerer');
      send(peers[0], { type: 'peer-ready', role: 'offerer' });
      send(peers[1], { type: 'peer-ready', role: 'answerer' });
    } else if (peers.length === 1) {
      roles.delete(peers[0]);
      send(peers[0], { type: 'waiting' });
    } else {
      roles.clear();
    }
  }

  function leave(socket) {
    const index = peers.indexOf(socket);
    if (index < 0) {
      return;
    } else {
      const peer = other(socket);
      peers.splice(index, 1);
      roles.delete(socket);
      if (peer !== null) {
        roles.delete(peer);
        send(peer, { type: 'peer-left' });
      } else {
        // No paired peer needs notification.
      }
      pair();
    }
  }

  function join(socket) {
    if (peers.length >= 2) {
      send(socket, { type: 'error', code: 'ROOM_FULL', message: 'Voice room already has two participants.' });
      socket.close(1008, 'Voice room is full.');
      return false;
    } else {
      peers.push(socket);
      pair();
      return true;
    }
  }

  function relay(socket, message) {
    const peer = other(socket);
    if (peer === null || roles.get(socket) === undefined) {
      throw new VoiceProtocolError('NO_PEER', 'No voice peer is connected.');
    } else if (message.type === 'offer' && roles.get(socket) !== 'offerer') {
      throw new VoiceProtocolError('INVALID_ROLE', 'Only the offerer may send an offer.');
    } else if (message.type === 'answer' && roles.get(socket) !== 'answerer') {
      throw new VoiceProtocolError('INVALID_ROLE', 'Only the answerer may send an answer.');
    } else {
      send(peer, message);
    }
  }

  function receive(socket, bytes) {
    try {
      const message = decodeVoiceMessage(bytes);
      switch (message.type) {
        case 'offer':
        case 'answer':
        case 'ice':
          relay(socket, message);
          break;
        case 'leave':
          leave(socket);
          socket.close(1000, 'Left voice room.');
          break;
        default:
          throw new VoiceProtocolError('INVALID_MESSAGE', 'Unsupported voice message.');
      }
    } catch (error) {
      if (error instanceof VoiceProtocolError) {
        send(socket, { type: 'error', code: error.code, message: error.message });
      } else {
        log.warn(error);
        send(socket, { type: 'error', code: 'INTERNAL_ERROR', message: 'Unable to process voice message.' });
      }
    }
  }

  return { join, leave, receive, size: () => peers.length };
}
