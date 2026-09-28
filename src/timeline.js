// Authoritative room calculation; independent of browser assets and effects.
export function positionAt(state, serverTimeMs) {
  switch (state.mode) {
    case 'empty': return 0;
    case 'paused': return state.positionSeconds;
    case 'playing':
      return state.positionSeconds + Math.max(0, serverTimeMs - state.anchorServerTimeMs) / 1000;
    default: throw new Error('Unsupported playback mode');
  }
}
