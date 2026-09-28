import { connectRoom } from './connection.js';
import { createPlayer } from './player.js';
import { isNewerState } from './timeline.js';
import { installFullscreen } from './fullscreen.js';

const ui = Object.fromEntries(['movies', 'video', 'play', 'pause', 'seek', 'volume', 'time', 'enable', 'status', 'connection', 'error', 'empty']
  .map((id) => [id, document.getElementById(id)]));

function showError(message) {
  ui.error.hidden = false;
  ui.error.textContent = message;
}

function timeLabel(seconds) {
  if (Number.isFinite(seconds)) {
    const whole = Math.floor(Math.max(0, seconds));
    return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`;
  } else {
    return '0:00';
  }
}

async function main() {
  installFullscreen({
    container: document.getElementById('player'), video: ui.video,
    button: document.getElementById('fullscreen'), onError: showError
  });
  const response = await fetch('/api/movies');
  if (!response.ok) {
    throw new Error('Could not load the movie catalog. Refresh to retry.');
  } else {
    const { movies } = await response.json();
    const catalog = new Map(movies.map((movie) => [movie.id, movie]));
    for (const movie of movies) {
      ui.movies.add(new Option(movie.title, movie.id));
    }
    ui.empty.hidden = movies.length !== 0;
    installRoom(catalog);
  }
}

function installRoom(catalog) {
  let latest = null;
  const player = createPlayer({
    video: ui.video, enable: ui.enable, catalog,
    send: (message) => room.send(message), serverNow: () => room.serverNow(),
    onStatus: (message) => { ui.status.textContent = message; },
    onError: showError, onChanged: refreshControls
  });
  const room = connectRoom({
    onConnected() {
      latest = null;
      ui.connection.textContent = 'Synchronizing clock…';
    },
    onReady() {
      ui.connection.textContent = 'Connected · one room';
      player.setConnected(true);
      if (latest !== null) {
        player.update(latest);
      } else {
        ui.status.textContent = 'Waiting for room state…';
      }
      refreshControls();
    },
    onState(state) {
      if (isNewerState(latest, state)) {
        latest = state;
        ui.movies.value = state.mediaId ?? '';
        ui.error.hidden = true;
        if (room.ready()) {
          player.update(state);
        } else {
          ui.status.textContent = 'Waiting for clock synchronization…';
        }
        refreshControls();
      } else {
        return;
      }
    },
    onDisconnected() {
      player.setConnected(false);
      ui.connection.textContent = 'Disconnected · retrying';
      ui.status.textContent = 'Playback paused locally. Reconnecting…';
      refreshControls();
    },
    onError: showError
  });

  function refreshControls() {
    const playable = room.ready() && latest !== null && latest.mode !== 'empty' && Number.isFinite(ui.video.duration);
    ui.movies.disabled = !room.ready() || catalog.size === 0;
    ui.play.disabled = !playable;
    ui.pause.disabled = !playable;
    ui.seek.disabled = !playable;
  }
  ui.movies.onchange = () => {
    if (catalog.has(ui.movies.value)) {
      room.send({ type: 'select', mediaId: ui.movies.value });
    } else {
      ui.movies.value = latest?.mediaId ?? '';
    }
  };
  ui.play.onclick = () => room.send({ type: 'play' });
  ui.pause.onclick = () => room.send({ type: 'pause' });
  ui.seek.onchange = () => room.send({ type: 'seek', positionSeconds: Number(ui.seek.value) });
  ui.volume.oninput = () => { ui.video.volume = Number(ui.volume.value); };
  ui.video.ondurationchange = () => {
    if (Number.isFinite(ui.video.duration)) {
      ui.seek.max = String(ui.video.duration);
    } else {
      ui.seek.max = '0';
    }
    refreshControls();
  };
  ui.video.ontimeupdate = () => {
    if (document.activeElement !== ui.seek) {
      ui.seek.value = String(ui.video.currentTime);
    } else {
      // Keep the user's in-progress seek position stable.
    }
    ui.time.textContent = `${timeLabel(ui.video.currentTime)} / ${timeLabel(ui.video.duration)}`;
  };
}

main().catch((error) => {
  ui.connection.textContent = 'Unable to connect';
  showError(error.message);
});
