import { readdir } from 'node:fs/promises';

// Only immediate regular files enter the catalog; directories/symlinks are excluded.
export async function readMediaCatalog(directory) {
  const files = await readdir(directory, { withFileTypes: true });
  return new Map(files
    .filter((file) => file.isFile() && /\.mp4$/i.test(file.name))
    .sort((left, right) => left.name.localeCompare(right.name))
    .map((file) => [file.name, {
      id: file.name,
      title: file.name.replace(/\.mp4$/i, ''),
      url: `/media/${encodeURIComponent(file.name)}`
    }]));
}
