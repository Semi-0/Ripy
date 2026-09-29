import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, rm, copyFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { chromium } from 'playwright';
import { buildServer } from '../src/server.js';
import { observeSockets, checkReflexEdges } from './reflex-edges.js';

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

async function checkVoice(a, b) {
  await a.click('#voice-join');
  await until(a, () => document.querySelector('#voice-status').textContent === 'WAITING FOR FRIEND');
  await b.click('#voice-join');
  for (const page of [a, b]) {
    await until(page, () => document.querySelector('#voice-status').textContent === 'CONNECTED');
    await until(page, () => document.querySelector('#voice-audio').srcObject !== null);
  }
  assert.equal(await a.locator('#movies').inputValue(), '');
  assert.equal(await b.locator('#movies').inputValue(), '');

  await a.click('#voice-mute');
  await until(a, () => document.querySelector('#voice-mute').getAttribute('aria-pressed') === 'true');
  assert.equal(await a.locator('#voice-mute').getAttribute('aria-pressed'), 'true');
  assert.equal(await b.locator('#voice-mute').getAttribute('aria-pressed'), 'false');
  await until(b, () => Math.abs(document.querySelector('video').volume - 1) < 0.001);
  const roomRevision = await a.evaluate(() => window.roomSockets().at(-1).snapshot.revision);
  await a.locator('#volume').fill('0.8');
  await until(a, () => Math.abs(document.querySelector('video').volume - 0.2) < 0.001);
  await a.locator('#volume').fill('0.4');
  await until(a, () => Math.abs(document.querySelector('video').volume - 0.1) < 0.001);
  assert.equal(await a.locator('#volume').inputValue(), '0.4');
  assert.equal(await b.locator('video').evaluate(video => video.volume), 1);
  await b.click('#voice-mute');
  await until(a, () => Math.abs(document.querySelector('video').volume - 0.4) < 0.001);
  await b.click('#voice-mute');
  await until(a, () => Math.abs(document.querySelector('video').volume - 0.1) < 0.001);
  assert.equal(await a.evaluate(() => window.roomSockets().at(-1).snapshot.revision), roomRevision);

  await b.click('#voice-leave');
  await until(b, () => document.querySelector('#voice-status').textContent === 'OFFLINE');
  await until(a, () => document.querySelector('#voice-status').textContent === 'WAITING FOR FRIEND');
  await until(a, () => Math.abs(document.querySelector('video').volume - 0.4) < 0.001);
  await b.evaluate(() => {
    const audio = document.querySelector('#voice-audio');
    const original = audio.play.bind(audio);
    audio.play = () => {
      audio.play = original;
      return Promise.reject(new DOMException('Test voice autoplay block', 'NotAllowedError'));
    };
  });
  await b.click('#voice-join');
  for (const page of [a, b]) {
    await until(page, () => document.querySelector('#voice-status').textContent === 'CONNECTED');
  }
  await until(a, () => Math.abs(document.querySelector('video').volume - 0.1) < 0.001);
  await b.locator('#voice-enable').waitFor({ state: 'visible' });
  await b.click('#voice-enable');
  await b.locator('#voice-enable').waitFor({ state: 'hidden' });
  console.log('PASS independent peer voice, local mute, leave/rejoin and autoplay recovery');
}

async function runChecks(a, b) {
  await checkVoice(a, b);
  await a.selectOption('#movies', 'test.mp4');
  await until(a, () => !document.querySelector('#play').disabled);
  await until(b, () => !document.querySelector('#play').disabled);
  const selectedRevision = await a.evaluate(() => window.roomSockets().at(-1).snapshot.revision);
  await a.selectOption('#movies', '');
  await until(a, () => document.querySelector('#movies').value === 'test.mp4');
  assert.equal(await a.evaluate(() => window.roomSockets().at(-1).snapshot.revision), selectedRevision);
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
  await until(a, () => document.querySelector('#voice-status').textContent === 'WAITING FOR FRIEND');
  await until(b, () => document.querySelector('#voice-status').textContent === 'OFFLINE');
  await b.click('#voice-join');
  for (const page of [a, b]) {
    await until(page, () => document.querySelector('#voice-status').textContent === 'CONNECTED');
  }
  console.log('PASS voice remains explicit after page reload and can rejoin');

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
  await until(a, () => Math.abs(document.querySelector('video').volume - 0.4) < 0.001);
  await until(a, () => !document.querySelector('#play').disabled);
  await until(b, () => !document.querySelector('#play').disabled);
  await checkTogether(a, b, false);
  for (const page of [a, b]) {
    await until(page, () => document.querySelector('#voice-status').textContent === 'CONNECTED');
  }
  await until(a, () => Math.abs(document.querySelector('video').volume - 0.1) < 0.001);
  console.log('PASS movie and voice transports reconnect independently');

  await a.click('#pause');
  await a.locator('#seek').fill('29.5');
  await a.locator('#seek').dispatchEvent('change');
  await until(b, () => document.querySelector('video').currentTime > 29);
  await a.click('#play');
  await until(a, () => document.querySelector('#status').textContent === 'Movie ended.');
  await checkTogether(a, b, true);
  console.log('PASS end of movie pauses room');

  // Rapid selection changes exercise cancellation of stale metadata/play effects.
  const replacements = Number(process.env.RAPID_REPEATS ?? 1);
  for (let attempt = 0; attempt < replacements; attempt += 1) {
    const expectedRevision = await a.evaluate(() => window.roomSockets().at(-1).snapshot.revision + 2);
    await a.selectOption('#movies', 'alternate.mp4');
    await a.selectOption('#movies', 'test.mp4');
    for (const page of [a, b]) {
      await page.waitForFunction(revision => window.roomSockets().at(-1).snapshot.revision >= revision,
        expectedRevision, { timeout: 12000 });
      await until(page, () => {
        const video = document.querySelector('video');
        return video.currentSrc.endsWith('/test.mp4') && video.currentTime < 0.2 && video.readyState >= 2;
      });
    }
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
  await a.bringToFront();
  await a.click('#fullscreen');
  await until(a, () => document.fullscreenElement?.id === 'player');
  assert.equal(await a.locator('#pause').isVisible(), true);
  await a.click('#fullscreen');
  await until(a, () => document.fullscreenElement === null);
  await a.locator('video').dblclick();
  await until(a, () => document.fullscreenElement?.id === 'player');
  await a.evaluate(() => document.exitFullscreen());
  console.log('PASS fullscreen entry, shared controls, exit and double-click');
  await a.evaluate(() => {
    document.querySelector('#player').requestFullscreen = () => Promise.reject(new Error('Controlled fullscreen rejection'));
  });
  await a.click('#fullscreen');
  await until(a, () => !document.querySelector('#error').hidden);
  assert.equal(await a.evaluate(() => document.fullscreenElement), null);
  await a.locator('#volume').fill('0.25');
  await until(a, () => Math.abs(document.querySelector('video').volume - 0.0625) < 0.001);
  assert.equal(await a.locator('#volume').inputValue(), '0.25');
  assert.equal(await b.locator('video').evaluate(video => video.volume), 1);
  console.log('PASS fullscreen error is visible and volume stays local');
}

try {
  await promisify(execFile)('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
    '-i', 'testsrc2=size=640x360:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=220:sample_rate=44100',
    '-t', '30', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-movflags', '+faststart', join(directory, 'test.mp4')]);
  await copyFile(join(directory, 'test.mp4'), join(directory, 'alternate.mp4'));
  app = await buildServer({ mediaDirectory: directory });
  const address = await app.listen({ host: '127.0.0.1', port: 0 });
  const launchOptions = {
    headless: true,
    args: [
      '--autoplay-policy=no-user-gesture-required',
      '--use-fake-device-for-media-stream',
      '--use-fake-ui-for-media-stream'
    ]
  };
  if (process.env.BROWSER_CHANNEL === 'chromium') {
    // CI uses Playwright's installed Chromium; local runs retain system Chrome.
  } else {
    launchOptions.channel = 'chrome';
  }
  browser = await chromium.launch(launchOptions);
  const context = await browser.newContext({ viewport: { width: 1100, height: 1000 } });
  await observeSockets(context);
  const a = await context.newPage();
  const b = await context.newPage();
  for (const page of [a, b]) {
    page.on('pageerror', (error) => errors.push(error.message));
    page.on('console', message => {
      if (message.text().includes('uncaught exception in Haskell')) {
        errors.push(message.text());
        console.error(message.text());
      } else {
        // Other browser diagnostics are not application exceptions.
      }
    });
    await page.goto(new URL(process.env.FRONTEND_PATH ?? '/', address).href);
    await until(page, () => !document.querySelector('#movies').disabled);
  }
  await runChecks(a, b);
  await checkReflexEdges(a);
  assert.deepEqual(errors, []);
  console.log('PASS no browser JavaScript errors');
} catch (error) {
  if (browser !== null) {
    for (const context of browser.contexts()) {
      for (const page of context.pages()) {
        console.error('Browser failure state:', await page.evaluate(() => {
          const video = document.querySelector('video');
          return { status: document.querySelector('#status')?.textContent, error: document.querySelector('#error')?.textContent,
            voiceStatus: document.querySelector('#voice-status')?.textContent,
            voiceError: document.querySelector('#voice-error')?.textContent,
            source: video?.currentSrc, position: video?.currentTime, readyState: video?.readyState, paused: video?.paused,
            snapshot: window.roomSockets?.().at(-1)?.snapshot };
        }));
      }
    }
  } else {
    // Browser setup failed before diagnostic pages existed.
  }
  throw error;
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
