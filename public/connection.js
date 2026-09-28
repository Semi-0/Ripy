import { clockSample, bestClockSample } from './timeline.js';

// Use a monotonic local clock for round trips and timeline estimates.
const now = () => performance.timeOrigin + performance.now();

export function connectRoom(handlers) {
  let socket = null;
  let offset = 0;
  let calibrated = false;
  let samples = [];
  let pendingPing = null;
  let pingTimeout = null;

  function send(message) {
    if (socket !== null && socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify(message));
      return true;
    } else {
      return false;
    }
  }

  function ping() {
    pendingPing = now();
    send({ type: 'ping', clientSentAtMs: pendingPing });
    clearTimeout(pingTimeout);
    pingTimeout = setTimeout(() => socket.close(), 5000);
  }

  function acceptPong(message) {
    if (message.clientSentAtMs !== pendingPing) {
      return;
    } else {
      clearTimeout(pingTimeout);
      samples.push(clockSample(pendingPing, now(), message.serverTimeMs));
      pendingPing = null;
      if (samples.length < 5) {
        ping();
      } else {
        offset = bestClockSample(samples).offset;
        if (!calibrated) {
          calibrated = true;
          handlers.onReady();
        } else {
          // Periodic recalibration adjusts the drift target without restarting playback.
        }
      }
    }
  }

  function open() {
    const url = new URL('/room', location.href);
    switch (url.protocol) {
      case 'http:': url.protocol = 'ws:'; break;
      case 'https:': url.protocol = 'wss:'; break;
      default: throw new Error('Unsupported website protocol');
    }
    const current = new WebSocket(url);
    socket = current;
    current.onopen = () => {
      samples = [];
      handlers.onConnected();
      ping();
    };
    current.onmessage = (event) => {
      if (socket !== current) {
        return;
      } else {
        const message = JSON.parse(event.data);
        switch (message.type) {
          case 'state': handlers.onState(message); break;
          case 'pong': acceptPong(message); break;
          case 'error': handlers.onError(message.message); break;
          default: handlers.onError('Unsupported server response.'); break;
        }
      }
    };
    current.onerror = () => current.close();
    current.onclose = () => {
      clearTimeout(pingTimeout);
      calibrated = false;
      pendingPing = null;
      handlers.onDisconnected();
      setTimeout(open, 2000);
    };
  }

  setInterval(() => {
    if (socket !== null && socket.readyState === WebSocket.OPEN && pendingPing === null) {
      samples = [];
      ping();
    } else {
      return;
    }
  }, 30000);
  open();
  return { send, serverNow: () => now() + offset, ready: () => calibrated };
}
