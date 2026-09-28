import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { installFrontend } from '../scripts/install-frontend.js';

test('artifact install validates commit and staged hashes before replacing assets', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'ripy-artifact-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const source = join(root, 'download');
  const destination = join(root, 'installed');
  await mkdir(source);
  await mkdir(destination);
  await writeFile(join(destination, 'all.js'), 'previous');
  const files = {};
  for (const name of ['all.js', 'index.html']) {
    const bytes = `built ${name}`;
    await writeFile(join(source, name), bytes);
    files[name] = createHash('sha256').update(bytes).digest('hex');
  }
  const commit = 'a'.repeat(40);
  await writeFile(join(source, 'build.json'), JSON.stringify({ commit, compiler: 'GHCJS', files }));
  await assert.rejects(installFrontend(source, 'b'.repeat(40), destination), /commit/);
  await writeFile(join(source, 'all.js'), 'corrupt');
  await assert.rejects(installFrontend(source, commit, destination), /hash mismatch/);
  assert.equal(await readFile(join(destination, 'all.js'), 'utf8'), 'previous');
  await writeFile(join(source, 'all.js'), 'built all.js');
  await installFrontend(source, commit, destination);
  assert.equal(await readFile(join(destination, 'all.js'), 'utf8'), 'built all.js');
  assert.equal(await readFile(join(`${destination}.previous`, 'all.js'), 'utf8'), 'previous');
});
