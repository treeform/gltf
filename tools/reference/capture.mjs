import { readFile, writeFile, mkdir, access } from 'node:fs/promises';
import { createServer } from 'node:http';
import { parseArgs } from 'node:util';
import path from 'node:path';
import { toolDir, assetsDir, rendererDir, cacheDir, sources, defaultManifest,
  git, sha256, checkedFile, safePath, writeJson, validateManifest } from './common.mjs';

const { values: args } = parseArgs({ options: {
  init: { type: 'boolean' }, force: { type: 'boolean' }, verify: { type: 'boolean' }, refit: { type: 'boolean' },
  software: { type: 'boolean' }, manifest: { type: 'string' }, out: { type: 'string' },
  'report-only': { type: 'boolean' },
  'export-environment': { type: 'boolean' },
  'all-models': { type: 'boolean' },
  expanded: { type: 'boolean' },
  models: { type: 'string' }, cases: { type: 'string' }
} });
const manifestFile = path.resolve(args.manifest || defaultManifest);
const outDir = path.resolve(args.out || path.dirname(manifestFile));
const pilotModels = ['AnimatedCube', 'DamagedHelmet', 'Fox', 'OrientationTest', 'SimpleMorph'];
const pilotLabels = { AnimatedCube: 'a0_t0p74', DamagedHelmet: 'rest', Fox: 'a2_t0p428583', OrientationTest: 'rest', SimpleMorph: 'a0_t1p48' };
const selectedModels = args.models?.split(',') || (args.init && !args['all-models'] ? pilotModels : undefined);
const selectedCases = args.cases?.split(',');
if (args.refit && selectedCases) throw new Error('--refit requires a complete model selection; use --models instead of --cases');
const settings = {
  width: 512, height: 512, renderFrames: 2, toneMap: 'KHR_PBR_NEUTRAL',
  fit: { yawDegrees: 20, pitchDegrees: 20, verticalFovDegrees: 45, padding: 1.25, marginPixels: 8 },
  excludedModels: { ABeautifulGame: 'Slow to load and provides little additional coverage for this suite.' },
  rendering: {
    clearColor: [0.7058824, 0.74509805, 0.8627451, 1],
    exposure: 1, useIBL: true, iblIntensity: 1, environmentRotation: 90,
    usePunctual: true, renderEnvironmentMap: false, blurEnvironmentMap: false,
    useDirectionalLightsWithDisabledIBL: false, internalMSAA: 4, floatingPointFramebuffer: true
  }
};
for (const [name, dir] of [['assets', assetsDir], ['renderer', rendererDir]]) {
  if (git(dir, 'rev-parse', 'HEAD') !== sources[name].revision) throw new Error(`${name} revision differs from sources.json`);
  if (git(dir, 'status', '--porcelain', '--untracked-files=no')) throw new Error(`${name} has modified tracked source files`);
}
await access(path.join(rendererDir, 'dist/gltf-viewer.module.js'));
const environment = JSON.parse(await readFile(path.join(cacheDir, 'environment.json'), 'utf8'));
if (environment.sha256 !== sha256(await readFile(path.join(cacheDir, 'neutral.hdr')))) throw new Error('Environment checksum mismatch');
let manifest;
if (args.init) {
  let exists = false;
  try { await access(manifestFile); exists = true; } catch {}
  if (exists && !args.force) throw new Error('Manifest exists. Capture it without --init, or explicitly use --force to replace cameras.');
  manifest = { version: 1, sources, environment, settings, cases: [], failures: [] };
} else {
  manifest = JSON.parse(await readFile(manifestFile, 'utf8'));
  validateManifest(manifest);
  if (JSON.stringify(manifest.sources) !== JSON.stringify(sources) || manifest.environment.sha256 !== environment.sha256) throw new Error('Manifest provenance differs from the installed sources');
}

const mime = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg', '.hdr': 'application/octet-stream' };
const server = createServer(async (req, res) => {
  try {
    const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    if (pathname === '/favicon.ico') { res.writeHead(204); res.end(); return; }
    const mounts = [['/renderer/', path.join(rendererDir, 'dist')], ['/math/', path.join(rendererDir, 'node_modules/gl-matrix/esm')], ['/models/', assetsDir], ['/environment/', cacheDir]];
    let root = toolDir, relative = pathname === '/' ? 'harness.html' : pathname.slice(1);
    for (const [prefix, dir] of mounts) if (pathname.startsWith(prefix)) { root = dir; relative = pathname.slice(prefix.length); break; }
    const filename = await checkedFile(root, relative);
    const bytes = await readFile(filename);
    res.writeHead(200, { 'Content-Type': mime[path.extname(filename)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(bytes);
  } catch (error) { res.writeHead(404); res.end(String(error.message)); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
process.env.PUPPETEER_CACHE_DIR ||= path.join(cacheDir, 'puppeteer');
const { default: puppeteer } = await import('puppeteer');
let browser;
let exportedEnvironment = false;
process.once('SIGINT', async () => { await browser?.close(); server.closeAllConnections(); server.close(); process.exit(130); });
let previous;
if (!args.init) {
  try { previous = JSON.parse(await readFile(path.join(outDir, 'run.json'), 'utf8')); } catch {}
}
const results = args['report-only'] ? previous?.captures || [] : [];
const run = args['report-only'] ? previous : { startedAt: new Date().toISOString(), sources: manifest.sources, manifestSha256: null, browser: null, gpu: null, captures: results };
const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
async function report() {
  run.finishedAt = new Date().toISOString();
  run.manifestSha256 = sha256(await readFile(manifestFile));
  await writeJson(path.join(outDir, 'run.json'), run);
  const tiles = results.map(item => `<article data-name="${escape(item.id.toLowerCase())}"><h2>${escape(item.id)}</h2>${item.status === 'ok' ? `<a href="images/${encodeURIComponent(item.id)}.png"><img loading="lazy" src="images/${encodeURIComponent(item.id)}.png" width="256" height="256"></a><p>${escape(item.animation || 'Rest pose')} · ${item.timeSeconds}s</p>` : `<p class="error">${escape(item.error)}</p>`}${item.warnings?.length ? `<details><summary>Renderer messages</summary><pre>${escape(item.warnings.join('\n'))}</pre></details>` : ''}</article>`).join('\n');
  await writeFile(path.join(outDir, 'index.html'), `<!doctype html><html><head><meta charset="utf-8"><title>Khronos glTF references</title><style>body{font:15px system-ui;background:#161a22;color:#e7ebf2;margin:32px}h1{font-size:28px}header{margin-bottom:24px}input{padding:12px;width:320px}main{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:16px}article{background:#242a35;padding:12px;border-radius:8px}h2{font-size:13px;overflow-wrap:anywhere}img{width:100%;height:auto}p{color:#bbc8dc}pre{white-space:pre-wrap}.error{color:#ffafa2}a{color:#b9d4ff}</style></head><body><header><h1>Khronos glTF references</h1><p>${results.filter(r => r.status === 'ok').length} captures · ${results.filter(r => r.status !== 'ok').length} failures · 512 × 512 · neutral studio</p><p>Renderer ${escape(manifest.sources.renderer.repository)} @ ${manifest.sources.renderer.revision.slice(0, 12)} · ${escape(run.browser)} · ${escape(run.gpu?.renderer || '')}</p><input id="filter" placeholder="Filter by model or animation"></header><main>${tiles}</main><script>document.querySelector('#filter').oninput=e=>document.querySelectorAll('article').forEach(x=>x.hidden=!x.dataset.name.includes(e.target.value.toLowerCase()));</script></body></html>`);
}

try {
  await mkdir(path.join(outDir, 'images'), { recursive: true });
  if (args['report-only']) {
    if (!run) throw new Error('No run.json exists to report');
    await report();
  } else {
  browser = await puppeteer.launch({ headless: true, protocolTimeout: 180000,
    args: ['--force-color-profile=srgb', ...(args.software ? ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] : [])] });
  run.browser = await browser.version();
  let jobs;
  if (args.init) {
    const index = JSON.parse(await readFile(path.join(assetsDir, 'Models/model-index.json'), 'utf8'));
    jobs = index.filter(m => !settings.excludedModels[m.name] && (!selectedModels || selectedModels.includes(m.name))).map(m => {
      const variant = m.variants.glTF ? 'glTF' : Object.keys(m.variants)[0];
      return { name: m.name, model: `Models/${m.name}/${variant}/${m.variants[variant]}` };
    });
  } else {
    const selected = manifest.cases.filter(c => (!selectedModels || selectedModels.includes(c.model.split('/')[1])) && (!selectedCases || selectedCases.includes(c.id)));
    jobs = [...new Set(selected.map(c => c.model))].map(model => ({ name: model.split('/')[1], model, cases: selected.filter(c => c.model === model) }));
  }
  if (!jobs.length) throw new Error('No models match the selection');
  for (const [index, job] of jobs.entries()) {
    console.log(`[${index + 1}/${jobs.length}] ${job.name}`);
    const page = await browser.newPage();
    const warnings = [], errors = [];
    page.on('console', message => {
      if (['warn', 'error'].includes(message.type())) warnings.push(message.text());
      if (message.type() === 'error') errors.push(message.text());
    });
    page.on('pageerror', error => errors.push(error.message));
    page.on('requestfailed', request => errors.push(`${request.url()}: ${request.failure()?.errorText}`));
    try {
      await page.setViewport({ width: manifest.settings.width, height: manifest.settings.height, deviceScaleFactor: 1 });
      await page.goto(origin, { waitUntil: 'load', timeout: 120000 });
      await page.waitForFunction('window.reference !== undefined || window.referenceError', { timeout: 30000 });
      const startupError = await page.evaluate(() => window.referenceError);
      if (startupError) throw new Error(startupError);
      const gpu = await page.evaluate(s => window.reference.initialize(s), manifest.settings);
      run.gpu ||= gpu;
      if (args['export-environment'] && !exportedEnvironment) {
        const directory = path.join(cacheDir, 'ibl');
        await mkdir(directory, { recursive: true });
        const hashes = {};
        await page.exposeFunction('saveEnvironmentTexture', async (file, encoded) => {
          const bytes = Buffer.from(encoded, 'base64');
          hashes[file] = sha256(bytes);
          await writeFile(safePath(directory, file), bytes);
        });
        const exported = await page.evaluate(() => window.reference.exportEnvironment());
        for (const texture of exported.textures) texture.sha256 = hashes[texture.file];
        await writeJson(path.join(directory, 'environment.json'), { ...exported, sources, gpu });
        exportedEnvironment = true;
        console.log(`  Exported filtered HDR environment: ${directory}`);
      }
      if (args.init) {
        const description = await page.evaluate((model, s) => window.reference.describe(model, s), job.model, manifest.settings);
        if (errors.length) throw new Error(errors.join('\n'));
        const base = job.name.replace(/[^A-Za-z0-9_.-]/g, '_');
        const samples = !args.expanded && !args['all-models']
          ? description.samples.filter(sample => sample.label === (pilotLabels[job.name] || 'rest'))
          : description.samples;
        job.cases = samples.map(sample => ({
          id: `${base}__${sample.label}`, model: job.model, scene: sample.scene,
          animationIndices: sample.animationIndices, timeSeconds: sample.timeSeconds,
          ...(sample.animationName ? { animationName: sample.animationName, animationEndSeconds: sample.animationEndSeconds } : {}),
          camera: description.camera
        }));
        manifest.cases.push(...job.cases);
      }
      if (args.init || args.refit) {
        manifest.settings.fit.marginPixels ??= 8;
        const camera = await page.evaluate((cases, s) => window.reference.fitCamera(cases, s), job.cases, manifest.settings);
        for (const item of job.cases) item.camera = camera;
        validateManifest(manifest);
        await writeJson(manifestFile, manifest);
      }
      for (const item of job.cases) {
        try {
          const encoded = await page.evaluate((c, s) => window.reference.capture(c, s), item, manifest.settings);
          if (errors.length) throw new Error(errors.join('\n'));
          const bytes = Buffer.from(encoded, 'base64');
          const hash = sha256(bytes);
          if (args.verify) {
            const repeat = await page.evaluate((c, s) => window.reference.capture(c, s), item, manifest.settings);
            if (hash !== sha256(Buffer.from(repeat, 'base64'))) {
              await writeFile(path.join(outDir, `${item.id}-first.png`), bytes);
              await writeFile(path.join(outDir, `${item.id}-repeat.png`), Buffer.from(repeat, 'base64'));
              throw new Error('Repeated capture changed at the same timestamp');
            }
          }
          await writeFile(safePath(path.join(outDir, 'images'), `${item.id}.png`), bytes);
          results.push({ id: item.id, status: 'ok', timeSeconds: item.timeSeconds, animation: item.animationName,
            sha256: hash, bytes: bytes.length, warnings: [...new Set(warnings)] });
          console.log(`  ${item.id}: ${bytes.length} bytes${args.verify ? ' (repeat verified)' : ''}`);
        } catch (error) {
          results.push({ id: item.id, status: 'error', error: error.message, warnings });
          console.error(`  ${item.id}: ${error.message.slice(0, 300)}`);
          continue;
        }
      }
    } catch (error) {
      console.error(`  FAILED: ${error.message.slice(0, 500)}`);
      if (args.init) { manifest.failures.push({ model: job.model, error: error.message }); await writeJson(manifestFile, manifest); }
      results.push({ id: job.name, status: 'error', error: error.message, warnings });
    } finally { await page.close(); }
    await report();
  }
  if (manifest.cases.length) validateManifest(manifest);
  console.log(`Report: ${path.join(outDir, 'index.html')}`);
  if (results.some(r => r.status !== 'ok')) process.exitCode = 1;
  }
} finally {
  await browser?.close();
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
