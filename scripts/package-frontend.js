import { mkdir, copyFile, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve, join } from 'node:path';

const source = resolve(process.argv[2]);
const destination = resolve('frontend-dist');
await mkdir(destination, { recursive: true });
await copyFile(join(source, 'all.js'), join(destination, 'all.js'));
await writeFile(join(destination, 'index.html'), `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ripy / Reflex</title><link rel="stylesheet" href="/assets/style.css"></head>
<body><script src="/reflex/all.js"></script></body></html>\n`);
const files = {};
for (const name of ['all.js', 'index.html']) {
  files[name] = createHash('sha256').update(await readFile(join(destination, name))).digest('hex');
}
await writeFile(join(destination, 'build.json'), JSON.stringify({
  commit: process.env.GITHUB_SHA, compiler: 'GHCJS',
  reflexPlatform: 'f231e2425ac92339b8491cdd970930d63d9ad1ad', files
}, null, 2) + '\n');
