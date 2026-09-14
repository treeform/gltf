import { access, mkdir, readFile, writeFile } from 'node:fs/promises';
import { execFileSync, execSync } from 'node:child_process';
import path from 'node:path';
import { assetsDir, rendererDir, cacheDir, sources, git, sha256, writeJson } from './common.mjs';

for (const [name, dir] of [['assets', assetsDir], ['renderer', rendererDir]]) {
  try { await access(path.join(dir, '.git')); }
  catch {
    execFileSync('git', ['clone', '--no-checkout', sources[name].repository, dir], { stdio: 'inherit' });
    git(dir, 'checkout', '--detach', sources[name].revision);
  }
  const revision = git(dir, 'rev-parse', 'HEAD');
  if (revision !== sources[name].revision) throw new Error(`${dir} is at ${revision}; expected ${sources[name].revision}. Use a separate checkout or update sources.json deliberately.`);
  if (git(dir, 'status', '--porcelain', '--untracked-files=no')) throw new Error(`${dir} has modified tracked files`);
  console.log(`${name}: ${revision}`);
}
execSync('npm ci --no-audit --no-fund', { cwd: rendererDir, stdio: 'inherit' });
execSync('npm run build', { cwd: rendererDir, stdio: 'inherit' });
await mkdir(cacheDir, { recursive: true });
for (const [url, filename] of [[sources.environment.url, 'neutral.hdr'], [sources.environment.licenseUrl, 'neutral.hdr.license'], [sources.draco.url, 'draco_decoder_gltf.js']]) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${response.status}: ${url}`);
  await writeFile(path.join(cacheDir, filename), Buffer.from(await response.arrayBuffer()));
}
const environmentSha256 = sha256(await readFile(path.join(cacheDir, 'neutral.hdr')));
if (environmentSha256 !== sources.environment.sha256) throw new Error('Downloaded environment checksum differs from sources.json');
await writeJson(path.join(cacheDir, 'environment.json'), { ...sources.environment, sha256: environmentSha256 });
console.log(`Ready. Environment SHA-256: ${environmentSha256}`);
