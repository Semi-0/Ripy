import { mkdir, copyFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';

const source = resolve(process.argv[2]);
const destination = resolve('frontend-dist');
await mkdir(destination, { recursive: true });
await copyFile(join(source, 'all.js'), join(destination, 'all.js'));
await writeFile(join(destination, 'index.html'), `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ripy / Reflex</title><link rel="stylesheet" href="/assets/style.css"></head>
<body><script src="/reflex/all.js"></script></body></html>\n`);
await writeFile(join(destination, 'build.json'), JSON.stringify({
  commit: process.env.GITHUB_SHA, compiler: 'GHCJS',
  reflexPlatform: 'f231e2425ac92339b8491cdd970930d63d9ad1ad'
}, null, 2) + '\n');
