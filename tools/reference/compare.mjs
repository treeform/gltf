import { spawnSync } from 'node:child_process';
import { mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { parseArgs } from 'node:util';
import path from 'node:path';
import { assetsDir, repoDir, defaultManifest, validateManifest, cacheDir, sources, sha256, safePath, git } from './common.mjs';

const { values: args } = parseArgs({ options: {
  manifest: { type: 'string' }, out: { type: 'string' }, case: { type: 'string' }, baselines: { type: 'string' },
  'no-build': { type: 'boolean' }, strict: { type: 'boolean' }, legacy: { type: 'boolean' }
} });
const manifest = path.resolve(args.manifest || defaultManifest);
const spec = JSON.parse(await readFile(manifest, 'utf8'));
validateManifest(spec);
const baselines = path.resolve(args.baselines || path.join(path.dirname(manifest), 'images'));
const referenceRun = JSON.parse(await readFile(path.join(path.dirname(baselines), 'run.json'), 'utf8'));
if (JSON.stringify(referenceRun.sources) !== JSON.stringify(spec.sources)) throw new Error('The master images use different renderer sources. Recapture before comparing.');
if (referenceRun.manifestSha256 !== sha256(await readFile(manifest))) throw new Error('The master images use a different manifest. Recapture before comparing.');
for (const item of spec.cases.filter(c => !args.case || c.id.includes(args.case))) {
  const capture = referenceRun.captures.find(c => c.id === item.id && c.status === 'ok');
  if (!capture || capture.sha256 !== sha256(await readFile(path.join(baselines, `${item.id}.png`)))) throw new Error(`Missing or stale master: ${item.id}. Recapture the selected cases.`);
}
const ibl = path.join(cacheDir, 'ibl');
if (!args.legacy) {
  if (spec.settings.toneMap !== 'KHR_PBR_NEUTRAL' || !spec.settings.rendering.useIBL || spec.settings.rendering.renderEnvironmentMap) throw new Error('Native pilot requires the neutral IBL profile with a solid background');
  let lighting;
  try { lighting = JSON.parse(await readFile(path.join(ibl, 'environment.json'), 'utf8')); }
  catch { throw new Error('Export the shared lighting once: npm run capture -- --export-environment --verify'); }
  if (JSON.stringify(lighting.sources) !== JSON.stringify(sources) || JSON.stringify(spec.sources) !== JSON.stringify(sources) || git(assetsDir, 'rev-parse', 'HEAD') !== sources.assets.revision) throw new Error('Sources changed; refresh the masters and lighting export');
  for (const texture of lighting.textures) {
    const bytes = await readFile(safePath(ibl, texture.file));
    if (sha256(bytes) !== texture.sha256) throw new Error(`Lighting checksum mismatch: ${texture.file}`);
  }
}
const outDir = path.resolve(args.out || path.join(repoDir, 'tests/tmp/reference'));
await mkdir(outDir, { recursive: true });
const executable = path.join(repoDir, 'tests/tmp/sample_assets_reference' + (process.platform === 'win32' ? '.exe' : ''));
if (!args['no-build']) {
  const build = spawnSync('nim', ['c', '--hints:off', `--nimcache:${path.join(repoDir, 'tests/tmp/reference-nimcache')}`,
    `-o:${executable}`, path.join(repoDir, 'tests/sample_assets.nim')], { cwd: repoDir, stdio: 'inherit' });
  if (build.error) throw build.error;
  if (build.status !== 0) process.exit(build.status || 1);
}
const start = performance.now();
// Never report a previous successful run after a crash before report creation.
await rm(path.join(outDir, 'metrics.json'), { force: true });
const render = spawnSync(executable, [`--manifest=${manifest}`, ...(args.case ? [`--case=${args.case}`] : []),
  ...(!args.legacy ? [`--ibl=${ibl}`] : []),
  path.join(assetsDir, 'Models'), outDir, baselines], { cwd: repoDir, encoding: 'utf8', maxBuffer: 20 * 1024 * 1024 });
if (render.error) throw render.error;
await writeFile(path.join(outDir, 'nim-run.log'), (render.stdout || '') + (render.stderr || ''));
let metrics;
try { metrics = JSON.parse(await readFile(path.join(outDir, 'metrics.json'), 'utf8')); }
catch { console.error(render.stdout, render.stderr); process.exit(1); }
console.table(metrics.map(m => ({ case: m.id, 'RGB MAE / 255': m.meanAbsoluteErrorRgb.toFixed(3),
  'different pixels': m.differentPixels, 'within ±2': m.pixels ? `${(100 * (m.pixels - m.pixelsOverTolerance2) / m.pixels).toFixed(2)}%` : 'n/a', status: m.status })));
console.log(`Rendered and compared ${metrics.length} cases in ${((performance.now() - start) / 1000).toFixed(2)}s.`);
console.log(`Report: ${path.join(outDir, 'xray_report.html')}`);
const errors = metrics.filter(m => !['ok', 'diff_error'].includes(m.status));
if (errors.length || (args.strict && render.status !== 0)) process.exitCode = 1;
