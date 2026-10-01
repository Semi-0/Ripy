import { buildServer, defaultMediaDirectory } from './server.js';
import { resolve } from 'node:path';
import { readAccessPassword, readAdminPassword } from './access-control.js';
import { readHttpsOptions } from './https-options.js';
import { readUploadMaxBytes } from './media-library.js';
import { loadPasswordEnvironment } from './password-configuration.js';

const mediaDirectory = resolve(process.env.MEDIA_DIRECTORY ?? defaultMediaDirectory);
const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? '127.0.0.1';
const passwordEnvironment = await loadPasswordEnvironment();
const accessPassword = readAccessPassword(passwordEnvironment);
const adminPassword = readAdminPassword(passwordEnvironment);
const mediaUploadMaxBytes = readUploadMaxBytes();
const https = await readHttpsOptions({
  keyPath: process.env.HTTPS_KEY_PATH,
  certPath: process.env.HTTPS_CERT_PATH
});
const app = await buildServer({
  mediaDirectory,
  logger: true,
  https,
  accessPassword,
  adminPassword,
  mediaUploadMaxBytes
});
await app.listen({ host, port });

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, async () => {
    await app.close();
  });
}
