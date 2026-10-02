import test from 'node:test';
import assert from 'node:assert/strict';
import { readTrustProxy } from '../src/proxy-options.js';

test('proxy trust is disabled unless loopback mode is explicit', () => {
  assert.equal(readTrustProxy({}), false);
  assert.equal(readTrustProxy({ TRUST_PROXY: '' }), false);
  assert.deepEqual(readTrustProxy({ TRUST_PROXY: 'loopback' }), ['127.0.0.1', '::1']);
  assert.throws(() => readTrustProxy({ TRUST_PROXY: 'true' }), /unset or equal to loopback/);
});
