import { createReadStream, createWriteStream } from 'node:fs';
import { link, open, readdir, unlink } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';
import { randomBytes } from 'node:crypto';
import { readMediaCatalog } from './catalog.js';

const temporaryPrefix = '.ripy-upload-';
export const defaultUploadMaxBytes = 20 * 1024 * 1024 * 1024;

export class MediaLibraryError extends Error {
  constructor(code, message, statusCode) {
    super(message);
    this.code = code;
    this.statusCode = statusCode;
  }
}

export function readUploadMaxBytes(environment = process.env) {
  const raw = environment.MEDIA_UPLOAD_MAX_BYTES;
  if (raw === undefined) {
    return defaultUploadMaxBytes;
  } else if (!/^\d+$/.test(raw)) {
    throw new Error('MEDIA_UPLOAD_MAX_BYTES must be a positive safe integer.');
  } else {
    const value = Number(raw);
    if (!Number.isSafeInteger(value) || value <= 0) {
      throw new Error('MEDIA_UPLOAD_MAX_BYTES must be a positive safe integer.');
    } else {
      return value;
    }
  }
}

export function validateMediaFilename(filename) {
  if (typeof filename !== 'string' || filename.length === 0) {
    throw new MediaLibraryError('INVALID_FILENAME', 'A movie filename is required.', 400);
  } else if (basename(filename) !== filename || filename.includes('/') || filename.includes('\\')) {
    throw new MediaLibraryError('INVALID_FILENAME', 'Movie filename must not contain a path.', 400);
  } else if (/[\u0000-\u001f\u007f]/.test(filename)) {
    throw new MediaLibraryError('INVALID_FILENAME', 'Movie filename contains control characters.', 400);
  } else if (filename.startsWith(temporaryPrefix)) {
    throw new MediaLibraryError('INVALID_FILENAME', 'Movie filename uses a reserved prefix.', 400);
  } else if (Buffer.byteLength(filename, 'utf8') > 200) {
    throw new MediaLibraryError('INVALID_FILENAME', 'Movie filename exceeds 200 UTF-8 bytes.', 400);
  } else if (!/\.mp4$/i.test(filename)) {
    throw new MediaLibraryError('INVALID_FILENAME', 'Movie filename must end in .mp4.', 400);
  } else {
    return filename;
  }
}

function entry(filename) {
  return {
    id: filename,
    title: filename.replace(/\.mp4$/i, ''),
    url: `/media/${encodeURIComponent(filename)}`
  };
}

async function removeTemporaryFiles(directory) {
  const files = await readdir(directory, { withFileTypes: true });
  await Promise.all(files
    .filter((item) => item.isFile() && item.name.startsWith(temporaryPrefix))
    .map((item) => unlink(join(directory, item.name))));
}

async function hasFtyp(path) {
  const handle = await open(path, 'r');
  try {
    const header = Buffer.alloc(12);
    const { bytesRead } = await handle.read(header, 0, header.length, 0);
    return bytesRead >= 8 && header.toString('ascii', 4, 8) === 'ftyp';
  } finally {
    await handle.close();
  }
}

function publicationError(error) {
  if (error !== null && error !== undefined && error.code === 'EEXIST') {
    return new MediaLibraryError('DUPLICATE_MEDIA', 'A movie with this filename already exists.', 409);
  } else {
    return error;
  }
}

export async function createMediaLibrary({
  directory,
  maxUploadBytes = defaultUploadMaxBytes
}) {
  if (!Number.isSafeInteger(maxUploadBytes) || maxUploadBytes <= 0) {
    throw new Error('Upload limit must be a positive safe integer.');
  } else {
    await removeTemporaryFiles(directory);
  }
  const catalog = await readMediaCatalog(directory);
  const subscribers = new Set();
  const publishing = new Set();
  let revision = 0;

  function snapshot() {
    return {
      revision,
      movies: [...catalog.values()].sort((left, right) => left.id.localeCompare(right.id))
    };
  }

  function notify() {
    const event = { revision };
    for (const subscriber of subscribers) {
      subscriber(event);
    }
  }

  function subscribe(subscriber) {
    subscribers.add(subscriber);
    subscriber({ revision });
    return () => subscribers.delete(subscriber);
  }

  async function upload({ filename: rawFilename, contentLength, stream }) {
    const filename = validateMediaFilename(rawFilename);
    if (!Number.isSafeInteger(contentLength) || contentLength <= 0) {
      throw new MediaLibraryError('INVALID_LENGTH', 'Content-Length must be a positive integer.', 411);
    } else if (contentLength > maxUploadBytes) {
      throw new MediaLibraryError('UPLOAD_TOO_LARGE', 'Movie exceeds the configured upload limit.', 413);
    } else if (catalog.has(filename) || publishing.has(filename)) {
      throw new MediaLibraryError('DUPLICATE_MEDIA', 'A movie with this filename already exists.', 409);
    } else {
      publishing.add(filename);
    }

    const temporaryName = `${temporaryPrefix}${randomBytes(16).toString('hex')}`;
    const temporaryPath = join(directory, temporaryName);
    const finalPath = join(directory, filename);
    let received = 0;
    const limitBytes = new Transform({
      transform(chunk, _encoding, callback) {
        received += chunk.length;
        if (received > contentLength || received > maxUploadBytes) {
          callback(new MediaLibraryError('UPLOAD_TOO_LARGE', 'Upload exceeded its declared or configured size.', 413));
        } else {
          callback(null, chunk);
        }
      }
    });
    try {
      await pipeline(stream, limitBytes, createWriteStream(temporaryPath, { flags: 'wx' }));
      if (received !== contentLength) {
        throw new MediaLibraryError('LENGTH_MISMATCH', 'Received bytes do not match Content-Length.', 400);
      } else if (!await hasFtyp(temporaryPath)) {
        throw new MediaLibraryError('INVALID_MEDIA', 'Uploaded file is not an MP4.', 415);
      } else {
        try {
          await link(temporaryPath, finalPath);
        } catch (error) {
          throw publicationError(error);
        }
        catalog.set(filename, entry(filename));
        revision += 1;
        notify();
        return entry(filename);
      }
    } finally {
      publishing.delete(filename);
      await unlink(temporaryPath).catch((error) => {
        if (error.code !== 'ENOENT') {
          throw error;
        }
      });
    }
  }

  async function remove(rawFilename) {
    const filename = validateMediaFilename(rawFilename);
    if (!catalog.has(filename)) {
      throw new MediaLibraryError('UNKNOWN_MEDIA', 'Movie is unavailable.', 404);
    } else {
      await unlink(join(directory, filename));
      catalog.delete(filename);
      revision += 1;
      notify();
      return filename;
    }
  }

  return {
    has: (filename) => catalog.has(filename),
    snapshot,
    subscribe,
    upload,
    remove,
    maxUploadBytes,
    createReadStream: (filename) => createReadStream(join(directory, validateMediaFilename(filename)))
  };
}
