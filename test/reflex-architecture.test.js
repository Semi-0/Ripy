import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../', import.meta.url);

async function source(path) {
  return readFile(new URL(path, root), 'utf8');
}

function imports(moduleName) {
  return new RegExp(`^import(?: qualified)? ${moduleName}(?:\\s|$)`, 'm');
}

test('atomic View has no application or domain dependencies', async () => {
  const view = await source('frontend/app/View.hs');
  for (const moduleName of ['Catalog', 'Connection', 'MovieView', 'Network', 'Player', 'Protocol', 'Selection']) {
    assert.doesNotMatch(view, imports(moduleName));
  }
  assert.match(view, /^buttonView ::/m);
  assert.match(view, /^choiceView ::/m);
  assert.match(view, /^rangeView ::/m);
});

test('MovieView composes presentation without behavior dependencies', async () => {
  const movieView = await source('frontend/app/MovieView.hs');
  for (const moduleName of ['Catalog', 'Connection', 'Network', 'Player', 'Protocol']) {
    assert.doesNotMatch(movieView, imports(moduleName));
  }
  assert.doesNotMatch(movieView, /\b(?:ClientCommand|Reaction|SendCommand)\b/);
  assert.match(movieView, /^data MovieSignals t/m);
});

test('Network does not depend on presentation modules', async () => {
  const network = await source('frontend/app/Network.hs');
  assert.doesNotMatch(network, imports('View'));
  assert.doesNotMatch(network, imports('MovieView'));
});

test('Main is the movie behavior specialization boundary', async () => {
  const main = await source('frontend/app/Main.hs');
  assert.match(main, /^specializeMovieSignals ::/m);
  assert.match(main, /Protocol\.SelectMovie/);
  assert.match(main, /playerMediaCommands/);
});
