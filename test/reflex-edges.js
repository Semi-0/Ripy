import assert from 'node:assert/strict';

// Instrument only the test page; production has no testing hooks or alternate protocol.
export async function observeSockets(context) {
  await context.addInitScript(() => {
    const NativeSocket = window.WebSocket;
    window.observedSockets = [];
    window.roomSockets = () => window.observedSockets.filter(socket => new URL(socket.url).pathname === '/room');
    window.WebSocket = class extends NativeSocket {
      constructor(...args) {
        super(...args);
        this.sent = [];
        this.addEventListener('open', () => { this.openedAt = performance.now(); });
        this.addEventListener('close', () => { this.closedAt = performance.now(); });
        window.observedSockets.push(this);
        this.addEventListener('message', (event) => {
          const parsed = JSON.parse(event.data);
          if (parsed.type === 'pong' && window.blockPongs === true) {
            event.stopImmediatePropagation();
          } else {
            // Normal messages reach the production Haskell callback.
          }
          if (parsed.type === 'state') {
            this.snapshot = parsed;
          } else {
            // Capture only real authoritative snapshots.
          }
        });
      }
      send(bytes) {
        this.sent.push(JSON.parse(bytes));
        super.send(bytes);
      }
    };
  });
}

export async function checkReflexEdges(page) {
  const initial = await page.locator('video').evaluate(video => video.currentTime);
  await page.evaluate(() => {
    const socket = window.roomSockets().at(-1);
    socket.onmessage({ data: '{' });
  });
  await page.waitForFunction(() => document.querySelector('#error').textContent.includes('Invalid server message'));
  assert.equal(await page.locator('video').evaluate(video => video.paused), true);
  assert.ok(Math.abs(await page.locator('video').evaluate(video => video.currentTime) - initial) < 0.2);
  await page.evaluate(() => {
    const socket = window.roomSockets().at(-1);
    socket.onmessage({ data: JSON.stringify({ ...socket.snapshot, revision: socket.snapshot.revision - 1, positionSeconds: 20, mode: 'playing' }) });
  });
  await page.waitForTimeout(300);
  assert.equal(await page.locator('video').evaluate(video => video.paused), true);
  assert.ok(Math.abs(await page.locator('video').evaluate(video => video.currentTime) - initial) < 0.2);
  await page.evaluate(() => {
    const socket = window.roomSockets().at(-1);
    socket.onmessage({ data: JSON.stringify({ type: 'state', epoch: 'test-new-server-epoch', revision: 0,
      mediaId: null, mode: 'empty', positionSeconds: 0, anchorServerTimeMs: Date.now(), pauseReason: null }) });
  });
  await page.waitForFunction(() => !document.querySelector('video').hasAttribute('src') && document.querySelector('#play').disabled);
  console.log('PASS malformed/stale snapshots preserve playback; new epoch resets room');
  await page.reload();
  await page.waitForFunction(() => !document.querySelector('#play').disabled);

  await page.evaluate(() => window.roomSockets().at(-1).close());
  await page.waitForFunction(() => window.roomSockets().length === 2 && !document.querySelector('#play').disabled);
  await page.evaluate(() => {
    const old = window.roomSockets()[0];
    old.dispatchEvent(new MessageEvent('message', { data: JSON.stringify({ ...old.snapshot, epoch: 'obsolete', mode: 'empty', mediaId: null }) }));
    old.dispatchEvent(new CloseEvent('close'));
  });
  await page.waitForTimeout(2200);
  assert.equal(await page.evaluate(() => window.roomSockets().length), 2);
  assert.equal(await page.locator('#play').isEnabled(), true);
  console.log('PASS obsolete connection events cannot reset playback or start another reconnect');

  // Keep a metadata request pending while a replacement selection arrives.
  await page.route('**/media/alternate.mp4', async route => {
    await new Promise(resolve => setTimeout(resolve, 1500));
    try {
      await route.continue();
    } catch (error) {
      // A superseded media request can be canceled before its delayed continuation.
      assert.match(error.message, /closed|handled|cancel|Invalid InterceptionId/i);
    }
  });
  await page.selectOption('#movies', 'alternate.mp4');
  await page.waitForTimeout(100);
  await page.selectOption('#movies', 'test.mp4');
  await page.waitForFunction(() => document.querySelector('video').currentSrc.endsWith('/test.mp4') && !document.querySelector('#play').disabled);
  await page.waitForTimeout(1800);
  assert.equal(await page.locator('video').evaluate(video => video.currentSrc.endsWith('/test.mp4')), true);
  assert.equal(await page.locator('video').evaluate(video => video.paused), true);
  console.log('PASS delayed obsolete metadata load cannot replace the latest movie');
  await page.waitForFunction(() => window.roomSockets().at(-1).sent.filter(x => x.type === 'ping').length >= 10,
    undefined, { timeout: 35000 });
  const pings = await page.evaluate(() => window.roomSockets().at(-1).sent.filter(x => x.type === 'ping'));
  assert.equal(pings.length, 10);
  const firstPing = await page.evaluate(() => window.roomSockets()[0].sent.find(x => x.type === 'ping').clientSentAtMs);
  assert.ok(pings[5].clientSentAtMs - firstPing >= 29000);
  console.log('PASS five initial clock samples and five-sample refresh after 30 seconds');

  const count = await page.evaluate(() => {
    window.blockPongs = true;
    window.roomSockets().at(-1).close();
    return window.roomSockets().length;
  });
  await page.waitForFunction(previousCount => window.roomSockets().length > previousCount &&
    window.roomSockets().at(-1).readyState === WebSocket.CLOSED, count, { timeout: 12000 });
  const lifetime = await page.evaluate(() => {
    const socket = window.roomSockets().at(-1);
    window.blockPongs = false;
    return socket.closedAt - socket.openedAt;
  });
  assert.ok(lifetime >= 4500 && lifetime < 8000, `Ping timeout: ${lifetime} ms`);
  await page.waitForFunction(() => !document.querySelector('#play').disabled);
  console.log('PASS unanswered ping closes after five seconds and reconnect recovers');
}
