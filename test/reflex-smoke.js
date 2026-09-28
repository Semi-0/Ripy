import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { buildServer } from '../src/server.js';

const app = await buildServer();
const url = await app.listen({ host: '127.0.0.1', port: 0 });
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(`${url}/reflex/`);
  await page.locator('[data-reflex-ready="true"]').waitFor();
  assert.match(await page.locator('h1').textContent(), /Reflex build verified/);
  assert.deepEqual(errors, []);
  console.log('Compiled Reflex browser page served by Node only: PASS');
} finally {
  await browser.close();
  await app.close();
}
