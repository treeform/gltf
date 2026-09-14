// Controlled experiment: inject the pinned Khronos WASM tangents into an
// isolated copy of DamagedHelmet, leaving the official assets/masters intact.
import { readFile, writeFile, mkdir, cp } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { assetsDir, rendererDir, repoDir, defaultManifest, writeJson, cacheDir, sources, git } from './common.mjs';

for (const [name, directory] of [['assets', assetsDir], ['renderer', rendererDir]]) {
  if (git(directory, 'rev-parse', 'HEAD') !== sources[name].revision ||
      git(directory, 'status', '--porcelain', '--untracked-files=no')) throw new Error(`Probe requires the clean pinned ${name} revision`);
}

const { default: init, generateTangents } = await import(pathToFileURL(path.join(rendererDir, 'source/libs/mikktspace.js')));
await init(await readFile(path.join(rendererDir, 'source/libs/mikktspace_bg.wasm')));
const source = path.join(assetsDir, 'Models/DamagedHelmet/glTF');
const model = JSON.parse(await readFile(path.join(source, 'DamagedHelmet.gltf'), 'utf8'));
const buffers = await Promise.all(model.buffers.map(b => readFile(path.join(source, b.uri))));
function accessor(index) {
  const a = model.accessors[index], b = model.bufferViews[a.bufferView];
  const width = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4 }[a.type];
  const bytes = { 5123: 2, 5125: 4, 5126: 4 }[a.componentType];
  if (!width || !bytes || a.normalized || a.sparse) throw new Error('Unsupported probe accessor');
  const data = buffers[b.buffer];
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const read = { 5123: 'getUint16', 5125: 'getUint32', 5126: 'getFloat32' }[a.componentType];
  return Array.from({ length: a.count }, (_, i) => Array.from({ length: width }, (_, j) =>
    view[read]((b.byteOffset || 0) + (a.byteOffset || 0) + i * (b.byteStride || width * bytes) + j * bytes, true)));
}
const outputRoot = path.join(repoDir, 'tests/tmp/tangent-probe');
const browserPixels = {};
if (process.argv.includes('--browser-jpegs')) {
  const { createServer } = await import('node:http');
  const server = createServer(async (req, res) => {
    const filename = req.url.slice(1);
    if (!model.images.some(image => image.uri === filename)) { res.writeHead(404); res.end(); return; }
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Content-Type', 'image/jpeg');
    res.end(await readFile(path.join(source, filename)));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  process.env.PUPPETEER_CACHE_DIR ||= path.join(cacheDir, 'puppeteer');
  const { default: puppeteer } = await import('puppeteer');
  let browser;
  try {
    browser = await puppeteer.launch({ headless: true, args: ['--force-color-profile=srgb'] });
    const page = await browser.newPage();
    for (const image of model.images) {
      const png = await page.evaluate(async url => {
        const image = new Image();
        image.crossOrigin = 'anonymous';
        image.src = url;
        await image.decode();
        const canvas = document.createElement('canvas');
        canvas.width = image.width; canvas.height = image.height;
        canvas.getContext('2d').drawImage(image, 0, 0);
        return canvas.toDataURL('image/png').split(',')[1];
      }, `http://127.0.0.1:${server.address().port}/${image.uri}`);
      browserPixels[image.uri] = Buffer.from(png, 'base64');
    }
  } finally { await browser?.close(); await new Promise(resolve => server.close(resolve)); }
}
const variants = ['khronos', 'opposite-sign', ...(Object.keys(browserPixels).length ? ['browser-normal-jpeg', 'browser-all-jpegs'] : [])];
for (const variant of variants) {
  const directory = path.join(outputRoot, variant, 'Models/DamagedHelmet/glTF');
  await mkdir(directory, { recursive: true });
  await cp(source, directory, { recursive: true });
  const gltf = structuredClone(model);
  for (const image of gltf.images) {
    if (variant === 'browser-all-jpegs' || (variant === 'browser-normal-jpeg' && image.uri.includes('normal'))) {
      await writeFile(path.join(directory, image.uri + '.png'), browserPixels[image.uri]);
      image.uri += '.png';
    }
  }
  const chunks = [];
  let offset = 0;
  function addAccessor(data, type) {
    const floats = Float32Array.from(data.flat());
    const bytes = Buffer.from(floats.buffer);
    chunks.push(bytes);
    gltf.bufferViews.push({ buffer: gltf.buffers.length, byteOffset: offset, byteLength: bytes.length });
    offset += bytes.length;
    gltf.accessors.push({ bufferView: gltf.bufferViews.length - 1, componentType: 5126, count: data.length, type });
    return gltf.accessors.length - 1;
  }
  for (const mesh of gltf.meshes) for (const primitive of mesh.primitives) {
    const indices = accessor(primitive.indices).flat();
    const attributes = Object.fromEntries(Object.entries(primitive.attributes).map(([name, index]) => {
      const data = accessor(index);
      return [name, indices.map(i => data[i])];
    }));
    const tangents = generateTangents(Float32Array.from(attributes.POSITION.flat()),
      Float32Array.from(attributes.NORMAL.flat()), Float32Array.from(attributes.TEXCOORD_0.flat()));
    const generated = Array.from({ length: indices.length }, (_, i) => [tangents[i * 4], tangents[i * 4 + 1],
      tangents[i * 4 + 2], tangents[i * 4 + 3] * (variant === 'opposite-sign' ? 1 : -1)]);
    for (const [name, data] of Object.entries(attributes)) primitive.attributes[name] = addAccessor(data, model.accessors[primitive.attributes[name]].type);
    primitive.attributes.TANGENT = addAccessor(generated, 'VEC4');
    delete primitive.indices;
    if (variant === 'khronos') await writeJson(path.join(outputRoot, 'khronos-tangents.json'), { sources, indices, tangents: generated });
  }
  gltf.buffers.push({ uri: 'tangent-probe.bin', byteLength: offset });
  await writeFile(path.join(directory, 'tangent-probe.bin'), Buffer.concat(chunks));
  await writeJson(path.join(directory, 'DamagedHelmet.gltf'), gltf);
  const out = path.join(outputRoot, variant, 'report');
  const executable = path.join(repoDir, 'tests/tmp/sample_assets_reference' + (process.platform === 'win32' ? '.exe' : ''));
  const run = spawnSync(executable, [`--manifest=${defaultManifest}`, '--case=DamagedHelmet',
    `--ibl=${path.join(repoDir, 'tools/reference/.cache/ibl')}`, path.join(directory, '../..'), out,
    path.join(repoDir, 'tests/reference/images')], { encoding: 'utf8', cwd: repoDir });
  await writeFile(path.join(out, 'nim-run.log'), (run.stdout || '') + (run.stderr || ''));
  const metrics = JSON.parse(await readFile(path.join(out, 'metrics.json')));
  console.log(variant, metrics);
}
