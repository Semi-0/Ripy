import { positionAt, clampPosition } from './timeline.js';

function waitForMetadata(video, signal) {
  return new Promise((resolve, reject) => {
    function finish(error) {
      clearTimeout(timer);
      video.removeEventListener('loadedmetadata', loaded);
      video.removeEventListener('error', failed);
      signal.removeEventListener('abort', aborted);
      if (error === null) {
        resolve();
      } else {
        reject(error);
      }
    }
    const loaded = () => finish(null);
    const failed = () => finish(new Error('Cannot load this movie. Check its format and restart after changing files.'));
    const aborted = () => finish(new DOMException('Superseded playback update', 'AbortError'));
    const timer = setTimeout(() => finish(new Error('Movie loading timed out. Try selecting it again.')), 15000);
    video.addEventListener('loadedmetadata', loaded);
    video.addEventListener('error', failed);
    signal.addEventListener('abort', aborted, { once: true });
    if (signal.aborted) {
      aborted();
    } else if (video.readyState >= 1) {
      loaded();
    } else {
      return;
    }
  });
}

export function createPlayer({ video, enable, catalog, send, serverNow, onStatus, onError, onChanged }) {
  let state = null;
  let connected = false;
  let loadedId = null;
  let generation = 0;
  let controller = new AbortController();
  let queue = Promise.resolve();
  let applying = false;
  let reportedStall = false;

  function target() {
    return clampPosition(positionAt(state, serverNow()), video.duration);
  }

  async function playOrEnable() {
    const version = generation;
    // play() can remain pending while the decoder waits for media data.
    const startupTimer = setTimeout(() => {
      if (version === generation && video.readyState < 3) {
        reportPause('buffering');
      } else {
        return;
      }
    }, 2000);
    try {
      await video.play();
      enable.hidden = true;
    } catch (error) {
      if (version !== generation) {
        return;
      } else if (error.name === 'NotAllowedError') {
        enable.hidden = false;
        onStatus('Your browser needs permission. Click Enable playback.');
      } else {
        throw error;
      }
    } finally {
      clearTimeout(startupTimer);
    }
  }

  async function loadMovie(next, signal) {
    if (!catalog.has(next.mediaId)) {
      throw new Error('Movie catalog changed. Refresh this page.');
    } else {
      if (loadedId !== next.mediaId || video.error !== null) {
        loadedId = next.mediaId;
        video.src = catalog.get(next.mediaId).url;
        video.load();
      } else {
        // Reuse this source, including an in-progress metadata request.
      }
      await waitForMetadata(video, signal);
    }
  }

  async function apply(next, version, signal) {
    if (version !== generation || !connected) {
      return;
    } else {
      switch (next.mode) {
        case 'empty':
          loadedId = null;
          video.removeAttribute('src');
          video.load();
          onStatus('Select a movie to begin.');
          return;
        case 'paused':
        case 'playing': await loadMovie(next, signal); break;
        default: throw new Error('Unsupported playback mode');
      }
      if (version !== generation || !connected) {
        return;
      } else {
        video.currentTime = target();
        switch (next.mode) {
          case 'paused':
            video.pause();
            onStatus(pauseMessage(next.pauseReason));
            break;
          case 'playing':
            onStatus('Watching together.');
            await playOrEnable();
            break;
          default: throw new Error('Unsupported playback mode');
        }
      }
    }
  }

  function update(next) {
    state = next;
    generation += 1;
    const version = generation;
    controller.abort();
    controller = new AbortController();
    const signal = controller.signal;
    applying = true;
    reportedStall = false;
    enable.hidden = true;
    video.pause();
    queue = queue.then(() => apply(next, version, signal)).catch((error) => {
      if (version === generation && error.name !== 'AbortError') {
        onError(error.message);
      } else {
        // Superseded effects no longer own the player or its error display.
      }
    }).finally(() => {
      if (version === generation) {
        applying = false;
        onChanged();
      } else {
        return;
      }
    });
  }

  function reportPause(reason) {
    if (connected && state !== null && state.mode === 'playing' && !reportedStall) {
      reportedStall = true;
      send({ type: 'pause', reason });
    } else {
      return;
    }
  }

  video.addEventListener('waiting', () => {
    if (!applying && !video.seeking) {
      reportPause('buffering');
    } else {
      return;
    }
  });
  video.addEventListener('ended', () => reportPause('ended'));
  video.addEventListener('error', () => {
    if (loadedId !== null) {
      onError('Movie playback failed. Check video/audio compatibility.');
      reportPause('buffering');
    } else {
      return;
    }
  });
  enable.onclick = () => {
    video.currentTime = target();
    playOrEnable().catch((error) => onError(error.message));
  };
  setInterval(() => {
    if (connected && state !== null && state.mode === 'playing' && !applying && !video.paused && video.readyState >= 2 && !video.seeking) {
      if (Math.abs(video.currentTime - target()) > 0.5) {
        video.currentTime = target();
      } else {
        return;
      }
    } else {
      return;
    }
  }, 1000);

  return {
    update,
    setConnected(value) {
      connected = value;
      if (!value) {
        generation += 1;
        controller.abort();
        video.pause();
        enable.hidden = true;
        applying = false;
      } else {
        return;
      }
    }
  };
}

function pauseMessage(reason) {
  switch (reason) {
    case 'buffering': return 'A viewer is buffering. Wait until ready, then press Play.';
    case 'ended': return 'Movie ended.';
    case 'selected': return 'Movie ready. Press Play when you are both ready.';
    case 'user': return 'Paused for everyone.';
    default: return 'Paused.';
  }
}
