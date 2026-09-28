// Fullscreen is local presentation; it never sends a room command.
export function installFullscreen({ container, video, button, onError }) {
  async function toggle() {
    try {
      if (document.fullscreenElement != null) {
        await document.exitFullscreen();
      } else if (typeof container.requestFullscreen === 'function') {
        await container.requestFullscreen();
      } else {
        onError('Fullscreen is not supported in this browser. Try opening this page in Chrome or Safari.');
      }
    } catch {
      onError('The browser could not change fullscreen. Try opening this page in a separate browser window.');
    }
  }

  function reflectFullscreen() {
    const active = document.fullscreenElement === container;
    button.setAttribute('aria-pressed', String(active));
    if (active) {
      button.textContent = '[ exit fullscreen ]';
    } else {
      button.textContent = '[ fullscreen ]';
    }
  }

  button.addEventListener('click', toggle);
  video.addEventListener('dblclick', toggle);
  document.addEventListener('fullscreenchange', reflectFullscreen);
  reflectFullscreen();
}
