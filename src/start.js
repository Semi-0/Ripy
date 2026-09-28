import { buildServer, defaultMediaDirectory } from './server.js';
import { resolve } from 'node:path';

const mediaDirectory = resolve(process.env.MEDIA_DIRECTORY ?? defaultMediaDirectory);
const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? '127.0.0.1';
const app = await buildServer({ mediaDirectory, logger: true });
await app.listen({ host, port });

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, async () => {
    await app.close();
  });
}
