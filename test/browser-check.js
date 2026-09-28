import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, rm, copyFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { chromium } from 'playwright';
import { buildServer } from '../src/server.js';

const directory = await mkdtemp(join(tmpdir(), 'cinema-browser-'));
const errors = [];
let app = null;
let browser = null;

async function until(page, predicate) {
  await page.waitForFunction(predicate, undefined, { timeout: 12000 });
}

async function playback(page) {
  return page.locator('video').evaluate((video) => ({ paused: video.paused, position: video.currentTime }));
}

async function checkTogether(a, b, paused) {
  for (const page of [a, b]) {
    await page.waitForFunction((expected) => document.querySelector('video').paused === expected, paused);
  }
  const left = await playback(a);
  const right = await playback(b);
  assert.ok(Math.abs(left.position - right.position) < 0.6, JSON.stringify({ left, right }));
}

async function runChecks(a, b) {
  await a.selectOption('#movies', 'test.mp4');
  await until(a, () => !document.querySelector('#play').disabled);
  await until(b, () => !document.querySelector('#play').disabled);
  await a.click('#play');
  await until(b, () => document.querySelector('video').currentTime > 1);
  await checkTogether(a, b, false);
  await b.click('#pause');
  await checkTogether(a, b, true);
  console.log('PASS two viewers play and pause');

  await b.locator('#seek').fill('12');
  await b.locator('#seek').dispatchEvent('change');
  await until(a, () => Math.abs(document.querySelector('video').currentTime - 12) < 0.2);
  await checkTogether(a, b, true);
  await b.click('#play');
  await until(a, () => !document.querySelector('video').paused);
  console.log('PASS shared seek and either-viewer control');

  await b.reload();
  await until(b, () => !document.querySelector('video').paused);
  await checkTogether(a, b, false);
  console.log('PASS late join while playing');

  // A controlled media event verifies policy independently from real network speed.
  await until(b, () => !document.querySelector('video').seeking);
  await b.locator('video').dispatchEvent('waiting');
  await checkTogether(a, b, true);
  assert.match(await a.locator('#status').textContent(), /buffering/);
  console.log('PASS controlled buffering pauses both viewers');

  // Simulate the browser's NotAllowedError; the recovery click uses the real player.
  await b.evaluate(() => {
    const video = document.querySelector('video');
    const original = video.play.bind(video);
    video.play = () => {
      video.play = original;
      return Promise.reject(new DOMException('Test autoplay block', 'NotAllowedError'));
    };
  });
  await a.click('#play');
  await b.locator('#enable').waitFor({ state: 'visible' });
  await b.click('#enable');
  await checkTogether(a, b, false);
  console.log('PASS controlled autoplay rejection and recovery');

  await a.click('#pause');
  await checkTogether(a, b, true);
  await b.evaluate(() => {
    const video = document.querySelector('video');
    const original = video.play.bind(video);
    video.play = () => {
      Object.defineProperty(video, 'readyState', { configurable: true, get: () => 0 });
      original().catch((error) => {
        if (error.name !== 'AbortError') {
          throw error;
        } else {
          // The simulated startup stall is deliberately interrupted by pause.
        }
      });
      return new Promise((_resolve, reject) => {
        video.addEventListener('pause', () => {
          delete video.readyState;
          video.play = original;
          reject(new DOMException('Paused while waiting for data', 'AbortError'));
        }, { once: true });
      });
    };
  });
  await a.click('#play');
  await until(a, () => document.querySelector('#status').textContent.includes('buffering'));
  await checkTogether(a, b, true);
  console.log('PASS controlled startup buffering pauses the room');
  await a.click('#play');
  await checkTogether(a, b, false);

  await b.locator('video').evaluate((video) => { video.currentTime += 3; });
  await until(b, () => !document.querySelector('video').seeking);
  await a.waitForTimeout(1500);
  await checkTogether(a, b, false);
  console.log('PASS drift over 0.5 seconds is corrected');

  for (const client of app.websocketServer.clients) {
    client.terminate();
  }
  await until(a, () => document.querySelector('#play').disabled && document.querySelector('video').paused);
  await until(a, () => !document.querySelector('#play').disabled);
  await until(b, () => !document.querySelector('#play').disabled);
  await checkTogether(a, b, false);
  console.log('PASS disconnection pauses locally, then reconnect catches up');

  await a.click('#pause');
  await a.locator('#seek').fill('29.5');
  await a.locator('#seek').dispatchEvent('change');
  await until(b, () => document.querySelector('video').currentTime > 29);
  await a.click('#play');
  await until(a, () => document.querySelector('#status').textContent === 'Movie ended.');
  await checkTogether(a, b, true);
  console.log('PASS end of movie pauses room');

  // Rapid selection changes exercise cancellation of stale metadata/play effects.
  await a.selectOption('#movies', 'alternate.mp4');
  await a.selectOption('#movies', 'test.mp4');
  for (const page of [a, b]) {
    await until(page, () => {
      const video = document.querySelector('video');
      return video.currentSrc.endsWith('/test.mp4') && video.currentTime < 0.2 && video.readyState >= 2;
    });
  }
  await checkTogether(a, b, true);
  await a.click('#play');
  await until(b, () => document.querySelector('video').currentTime > 0.5);
  await a.click('#pause');
  await checkTogether(a, b, true);
  await mkdir('test-results', { recursive: true });
  await a.screenshot({ path: 'test-results/browser.png', fullPage: true });
  await a.setViewportSize({ width: 390, height: 844 });
  assert.equal(await a.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await a.screenshot({ path: 'test-results/mobile.png', fullPage: true });
  console.log('PASS rapid movie selection and narrow-screen layout');
  await a.click('#fullscreen');
  await until(a, () => document.fullscreenElement?.id === 'player');
  assert.equal(await a.locator('#pause').isVisible(), true);
  await a.click('#fullscreen');
  await until(a, () => document.fullscreenElement === null);
  await a.locator('video').dblclick();
  await until(a, () => document.fullscreenElement?.id === 'player');
  await a.evaluate(() => document.exitFullscreen());
  console.log('PASS fullscreen entry, shared controls, exit and double-click');
}

try {
  await promisify(execFile)('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
    '-i', 'testsrc2=size=640x360:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=220:sample_rate=44100',
    '-t', '30', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-movflags', '+faststart', join(directory, 'test.mp4')]);
  await copyFile(join(directory, 'test.mp4'), join(directory, 'alternate.mp4'));
  app = await buildServer({ mediaDirectory: directory });
  const address = await app.listen({ host: '127.0.0.1', port: 0 });
  const launchOptions = { headless: true, args: ['--autoplay-policy=no-user-gesture-required'] };
  if (process.env.BROWSER_CHANNEL === 'chromium') {
    // CI uses Playwright's installed Chromium; local runs retain system Chrome.
  } else {
    launchOptions.channel = 'chrome';
  }
  browser = await chromium.launch(launchOptions);
  const context = await browser.newContext({ viewport: { width: 1100, height: 1000 } });
  const a = await context.newPage();
  const b = await context.newPage();
  for (const page of [a, b]) {
    page.on('pageerror', (error) => errors.push(error.message));
    await page.goto(new URL(process.env.FRONTEND_PATH ?? '/', address).href);
    await until(page, () => !document.querySelector('#movies').disabled);
  }
  await runChecks(a, b);
  assert.deepEqual(errors, []);
  console.log('PASS no browser JavaScript errors');
} finally {
  if (browser !== null) {
    await browser.close();
  } else {
    // Browser launch failed; only server/temp resources need cleanup.
  }
  if (app !== null) {
    for (const client of app.websocketServer.clients) {
      client.terminate();
    }
    await app.close();
  } else {
    // Setup failed before server creation.
  }
  await rm(directory, { recursive: true, force: true });
}
