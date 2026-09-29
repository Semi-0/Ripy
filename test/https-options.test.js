import test from 'node:test';
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { readHttpsOptions } from '../src/https-options.js';

test('HTTPS stays disabled when neither certificate path is configured', async () => {
  assert.equal(await readHttpsOptions(), undefined);
});

test('HTTPS requires key and certificate paths together', async () => {
  await assert.rejects(
    readHttpsOptions({ certPath: 'cert.pem' }),
    /HTTPS_KEY_PATH is required/
  );
  await assert.rejects(
    readHttpsOptions({ keyPath: 'key.pem' }),
    /HTTPS_CERT_PATH is required/
  );
});

test('HTTPS reads the resolved key and certificate paths', async () => {
  const reads = [];
  const read = async (path) => {
    reads.push(path);
    if (path === resolve('key.pem')) {
      return Buffer.from('key');
    } else if (path === resolve('cert.pem')) {
      return Buffer.from('cert');
    } else {
      throw new Error(`Unexpected path: ${path}`);
    }
  };
  const options = await readHttpsOptions({ keyPath: 'key.pem', certPath: 'cert.pem', read });
  assert.deepEqual(options, { key: Buffer.from('key'), cert: Buffer.from('cert') });
  assert.deepEqual(reads, [resolve('key.pem'), resolve('cert.pem')]);
});
