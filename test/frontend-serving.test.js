import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { buildServer } from '../src/server.js';

test('missing or partial frontend returns installation instructions without breaking API', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'ripy-missing-frontend-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await writeFile(join(directory, 'index.html'), '<main>Incomplete download</main>');
  const app = await buildServer({ mediaDirectory: directory, frontendDirectory: directory });
  t.after(() => app.close());
  const page = await app.inject('/');
  assert.equal(page.statusCode, 503);
  assert.match(page.body, /frontend\/README.md/);
  assert.deepEqual((await app.inject('/api/movies')).json(), { movies: [] });
});

test('obsolete handwritten browser modules are no longer served', async (t) => {
  const app = await buildServer();
  t.after(() => app.close());
  for (const filename of ['app.js', 'connection.js', 'player.js', 'fullscreen.js', 'timeline.js']) {
    assert.equal((await app.inject(`/assets/${filename}`)).statusCode, 404);
  }
  assert.equal((await app.inject('/assets/style.css')).statusCode, 200);
});
