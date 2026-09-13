import { readFile, writeFile, mkdir, realpath } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const toolDir = path.dirname(fileURLToPath(import.meta.url));
export const repoDir = path.resolve(toolDir, '../..');
export const rendererDir = path.resolve(process.env.GLTF_REFERENCE_RENDERER || path.join(repoDir, '../glTF-Sample-Renderer'));
export const assetsDir = path.resolve(process.env.GLTF_SAMPLE_ASSETS || path.join(repoDir, '../glTF-Sample-Assets'));
export const cacheDir = path.join(toolDir, '.cache');
export const sources = JSON.parse(await readFile(path.join(toolDir, 'sources.json'), 'utf8'));
export const defaultManifest = path.join(repoDir, 'tests/reference/manifest.json');
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
export const git = (dir, ...args) => execFileSync('git', ['-c', `safe.directory=${dir.replaceAll('\\', '/')}`, '-C', dir, ...args], { encoding: 'utf8' }).trim();
export async function writeJson(filename, data) {
  await mkdir(path.dirname(filename), { recursive: true });
  await writeFile(filename, JSON.stringify(data, null, 2) + '\n');
}
export function safePath(root, relative) {
  const target = path.resolve(root, relative);
  const rel = path.relative(root, target);
  if (rel === '..' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) throw new Error(`Path escapes root: ${relative}`);
  return target;
}
export async function checkedFile(root, relative) {
  const file = await realpath(safePath(root, relative));
  safePath(await realpath(root), path.relative(await realpath(root), file));
  return file;
}
export function validateManifest(manifest) {
  if (manifest.version !== 1 || !Array.isArray(manifest.cases) || !manifest.cases.length) throw new Error('Expected a version 1 manifest with cases');
  for (const key of ['width', 'height', 'renderFrames']) {
    const v = manifest.settings?.[key];
    if (!Number.isInteger(v) || v <= 0 || v > (key === 'renderFrames' ? 10 : 4096)) throw new Error(`Invalid ${key}`);
  }
  const ids = new Set();
  for (const item of manifest.cases) {
    if (!/^[A-Za-z0-9_.-]+$/.test(item.id) || ids.has(item.id)) throw new Error(`Invalid or duplicate case id: ${item.id}`);
    ids.add(item.id);
    if (typeof item.model !== 'string' || !item.model.startsWith('Models/')) throw new Error(`Invalid model path: ${item.id}`);
    safePath(assetsDir, item.model);
    if (!Number.isInteger(item.scene) || item.scene < 0) throw new Error(`Invalid scene: ${item.id}`);
    if (!Number.isFinite(item.timeSeconds) || item.timeSeconds < 0) throw new Error(`Invalid time: ${item.id}`);
    if (!Array.isArray(item.animationIndices) || item.animationIndices.some(i => !Number.isInteger(i) || i < 0)) throw new Error(`Invalid animations: ${item.id}`);
    for (const key of ['position', 'target', 'up']) {
      if (item.camera?.[key]?.length !== 3 || !item.camera[key].every(Number.isFinite)) throw new Error(`Invalid camera ${key}: ${item.id}`);
    }
    const c = item.camera;
    if (!(c.verticalFovDegrees > 0 && c.verticalFovDegrees < 180 && c.near > 0 && c.far > c.near)) throw new Error(`Invalid projection: ${item.id}`);
    const d = c.position.map((v, i) => v - c.target[i]);
    const cross = [d[1] * c.up[2] - d[2] * c.up[1], d[2] * c.up[0] - d[0] * c.up[2], d[0] * c.up[1] - d[1] * c.up[0]];
    if (Math.hypot(...cross) < 1e-10) throw new Error(`Degenerate camera: ${item.id}`);
  }
}
