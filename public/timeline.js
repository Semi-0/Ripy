// Shared pure timeline functions: no browser, network, or filesystem effects.
export function positionAt(state, serverTimeMs) {
  switch (state.mode) {
    case 'empty': return 0;
    case 'paused': return state.positionSeconds;
    case 'playing':
      return state.positionSeconds + Math.max(0, serverTimeMs - state.anchorServerTimeMs) / 1000;
    default: throw new Error('Unsupported playback mode');
  }
}

export function isNewerState(current, incoming) {
  switch (true) {
    case current === null: return true;
    case current.epoch !== incoming.epoch: return true;
    default: return incoming.revision > current.revision;
  }
}

export function clampPosition(position, duration) {
  switch (Number.isFinite(duration) && duration >= 0) {
    case true: return Math.min(duration, Math.max(0, position));
    case false: return 0;
    default: throw new Error('Invalid duration check');
  }
}

export function clockSample(sent, received, serverTime) {
  return { roundTrip: received - sent, offset: serverTime - (sent + received) / 2 };
}

export function bestClockSample(samples) {
  switch (samples.length) {
    case 0: throw new Error('At least one clock sample is required');
    default: return samples.reduce((best, sample) => {
      switch (sample.roundTrip < best.roundTrip) {
        case true: return sample;
        case false: return best;
        default: throw new Error('Invalid round trip comparison');
      }
    });
  }
}
