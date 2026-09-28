import test from 'node:test';
import assert from 'node:assert/strict';
import { createEmptyRoom, transitionRoom } from '../src/room.js';
import { decodeAndValidate } from '../src/protocol.js';
import { positionAt } from '../src/timeline.js';

const catalog = new Map([['movie.mp4', {}], ['second.mp4', {}]]);
const empty = createEmptyRoom('epoch-a', 1000);
const selected = transitionRoom(empty, { type: 'select', mediaId: 'movie.mp4' }, 2000, catalog);

test('select, play, seek, pause, resume, and replacement preserve timeline semantics', () => {
  const playing = transitionRoom(selected, { type: 'play' }, 3000, catalog);
  assert.equal(positionAt(playing, 6500), 3.5);
  assert.equal(positionAt(playing, 2000), 0);
  const seek = transitionRoom(playing, { type: 'seek', positionSeconds: 120 }, 7000, catalog);
  assert.equal(seek.mode, 'playing');
  const paused = transitionRoom(seek, { type: 'pause', reason: 'buffering' }, 9000, catalog);
  assert.equal(paused.positionSeconds, 122);
  assert.equal(positionAt(paused, 100000), 122);
  assert.equal(paused.pauseReason, 'buffering');
  const pausedSeek = transitionRoom(paused, { type: 'seek', positionSeconds: 10 }, 10000, catalog);
  assert.equal(pausedSeek.mode, 'paused');
  const resumed = transitionRoom(pausedSeek, { type: 'play' }, 11000, catalog);
  assert.equal(positionAt(resumed, 13000), 12);
  const replacement = transitionRoom(resumed, { type: 'select', mediaId: 'second.mp4' }, 14000, catalog);
  assert.equal(replacement.positionSeconds, 0);
  assert.equal(replacement.mode, 'paused');
  assert.equal(replacement.revision, 7);
  assert.equal(selected.positionSeconds, 0, 'previous states are not mutated');
  assert.equal(positionAt(empty, 2000), 0);
  assert.throws(() => positionAt({ mode: 'invalid' }, 0));
});

test('server arrival order determines concurrent control outcomes', () => {
  const played = transitionRoom(selected, { type: 'play' }, 3000, catalog);
  const paused = transitionRoom(played, { type: 'pause', reason: 'user' }, 3000, catalog);
  assert.equal(paused.mode, 'paused');
  assert.equal(paused.revision, 3);
});

test('missing media and unsupported transitions do not mutate state', () => {
  for (const command of [{ type: 'play' }, { type: 'pause' }, { type: 'seek', positionSeconds: 0 }]) {
    assert.throws(() => transitionRoom(empty, command, 1000, catalog), { code: 'NO_MEDIA' });
  }
  assert.throws(() => transitionRoom(selected, { type: 'select', mediaId: '../secret.mp4' }, 1000, catalog), { code: 'UNKNOWN_MEDIA' });
  assert.throws(() => transitionRoom(selected, { type: 'unknown' }, 1000, catalog), { code: 'INVALID_MESSAGE' });
  assert.equal(empty.revision, 0);
});

test('protocol rejects malformed, unexpected, and nonfinite fields', () => {
  const invalid = ['{', 'null', '[]', '42', '{}', '{"type":"seek","positionSeconds":1e999}',
    ...[{ type: 'seek', positionSeconds: -1 }, { type: 'seek', positionSeconds: '12' },
      { type: 'select', mediaId: '' }, { type: 'play', extra: true }, { type: 'pause', reason: 'nope' },
      { type: 'ping' }, { type: 'unknown' }].map(JSON.stringify)];
  for (const message of invalid) {
    assert.throws(() => decodeAndValidate(Buffer.from(message)), { code: 'INVALID_MESSAGE' });
  }
  assert.deepEqual(decodeAndValidate('{"type":"pause"}'), { type: 'pause', reason: 'user' });
  for (const message of [{ type: 'select', mediaId: 'movie.mp4' }, { type: 'play' },
    { type: 'seek', positionSeconds: 0 }, { type: 'ping', clientSentAtMs: 10 },
    { type: 'pause', reason: 'ended' }]) {
    assert.deepEqual(decodeAndValidate(JSON.stringify(message)), message);
  }
});
