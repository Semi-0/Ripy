import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';
import { loadPasswordEnvironment } from '../src/password-configuration.js';

async function configurationFile(source) {
  const directory = await mkdtemp(join(tmpdir(), 'ripy-config-'));
  const path = join(directory, 'ripy.config.mjs');
  await writeFile(path, source);
  return pathToFileURL(path);
}

test('local JavaScript config supplies both server passwords', async () => {
  const configUrl = await configurationFile(`export default {
    roomPassword: 'local room password',
    mediaAdminPassword: 'local admin password'
  };`);
  const result = await loadPasswordEnvironment({ environment: {}, configUrl });
  assert.deepEqual(result, {
    ROOM_PASSWORD: 'local room password',
    MEDIA_ADMIN_PASSWORD: 'local admin password'
  });
});

test('environment passwords override local JavaScript config', async () => {
  const configUrl = await configurationFile(`export default {
    roomPassword: 'local room password',
    mediaAdminPassword: 'local admin password'
  };`);
  const environment = {
    ROOM_PASSWORD: 'environment room password',
    MEDIA_ADMIN_PASSWORD: 'environment admin password'
  };
  const result = await loadPasswordEnvironment({ environment, configUrl });
  assert.deepEqual(result, environment);
});

test('missing config leaves passwords disabled', async () => {
  const configUrl = pathToFileURL(join(tmpdir(), 'missing-ripy-config.mjs'));
  const result = await loadPasswordEnvironment({ environment: {}, configUrl });
  assert.deepEqual(result, {
    ROOM_PASSWORD: undefined,
    MEDIA_ADMIN_PASSWORD: undefined
  });
});

test('invalid local configuration is rejected', async () => {
  const configUrl = await configurationFile(`export default { typo: 'password' };`);
  await assert.rejects(
    loadPasswordEnvironment({ environment: {}, configUrl }),
    /Unsupported ripy.config.js setting: typo/
  );
});
