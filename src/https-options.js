import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

function configuredPath(value) {
  if (typeof value === 'string' && value.trim().length > 0) {
    return resolve(value);
  } else {
    return null;
  }
}

export async function readHttpsOptions({ keyPath, certPath, read = readFile } = {}) {
  const keyFile = configuredPath(keyPath);
  const certFile = configuredPath(certPath);
  if (keyFile === null && certFile === null) {
    return undefined;
  } else if (keyFile === null) {
    throw new Error('HTTPS_KEY_PATH is required when HTTPS_CERT_PATH is set.');
  } else if (certFile === null) {
    throw new Error('HTTPS_CERT_PATH is required when HTTPS_KEY_PATH is set.');
  } else {
    const [key, cert] = await Promise.all([read(keyFile), read(certFile)]);
    return { key, cert };
  }
}
