import { createHash } from 'node:crypto';
import { lstat, readFile, mkdtemp, copyFile, rename, rm } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const project = fileURLToPath(new URL('../', import.meta.url));
const expectedFiles = ['all.js', 'index.html'];

// Hashes detect damaged downloads; obtain artifacts from the trusted CI run.
export async function installFrontend(source, expectedCommit, destination = join(project, 'frontend-dist')) {
  if (!/^[0-9a-f]{40}$/.test(expectedCommit ?? '')) {
    throw new Error('Supply the full expected Git commit SHA.');
  } else {
    const manifest = JSON.parse(await readFile(join(source, 'build.json'), 'utf8'));
    if (manifest.commit !== expectedCommit || manifest.compiler !== 'GHCJS') {
      throw new Error('Artifact commit or compiler does not match.');
    } else {
      await stageAndInstall(source, manifest, destination);
    }
  }
}

async function stageAndInstall(source, manifest, destination) {
  const stage = await mkdtemp(join(dirname(destination), '.reflex-stage-'));
  try {
    for (const name of expectedFiles) {
      const path = join(source, name);
      const stat = await lstat(path);
      if (!stat.isFile() || stat.size === 0) {
        throw new Error(`Artifact must contain a nonempty regular file: ${name}`);
      } else {
        await copyFile(path, join(stage, name));
        const bytes = await readFile(join(stage, name));
        const digest = createHash('sha256').update(bytes).digest('hex');
        if (manifest.files?.[name] !== digest) {
          throw new Error(`Artifact hash mismatch: ${name}`);
        } else {
          // Validate the staged bytes, not a source that could change later.
        }
      }
    }
    await copyFile(join(source, 'build.json'), join(stage, 'build.json'));
    await replaceWithBackup(stage, destination);
  } finally {
    await rm(stage, { recursive: true, force: true });
  }
}

async function replaceWithBackup(stage, destination) {
  const backup = `${destination}.previous`;
  let hadPrevious = false;
  try {
    await lstat(destination);
    hadPrevious = true;
  } catch (error) {
    if (error.code !== 'ENOENT') {
      throw error;
    } else {
      // First installation has no previous assets.
    }
  }
  if (hadPrevious) {
    await rm(backup, { recursive: true, force: true });
    await rename(destination, backup);
  } else {
    // Keep any existing rollback copy on a first installation.
  }
  try {
    await rename(stage, destination);
  } catch (error) {
    if (hadPrevious) {
      await rename(backup, destination);
    } else {
      // Nothing was replaced.
    }
    throw error;
  }
}

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [, , source, commit] = process.argv;
  if (source === undefined) {
    throw new Error('Usage: node scripts/install-frontend.js DOWNLOAD_DIRECTORY COMMIT_SHA');
  } else {
    await installFrontend(resolve(source), commit);
    console.log('Verified frontend installed; restart Fastify and open http://localhost:3000/.');
  }
} else {
  // Imported by the installer tests.
}
