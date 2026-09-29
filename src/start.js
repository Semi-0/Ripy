import { buildServer, defaultMediaDirectory } from './server.js';
import { resolve } from 'node:path';
import { readHttpsOptions } from './https-options.js';

const mediaDirectory = resolve(process.env.MEDIA_DIRECTORY ?? defaultMediaDirectory);
const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? '127.0.0.1';
const https = await readHttpsOptions({
  keyPath: process.env.HTTPS_KEY_PATH,
  certPath: process.env.HTTPS_CERT_PATH
});
const app = await buildServer({ mediaDirectory, logger: true, https });
await app.listen({ host, port });

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, async () => {
    await app.close();
  });
}
