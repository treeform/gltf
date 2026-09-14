import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { defaultManifest, validateManifest, safePath, sha256,
  retainedCaptures } from './common.mjs';

const manifest = JSON.parse(await readFile(defaultManifest, 'utf8'));
test('the catalog covers every selected model and later animation poses', () => {
  validateManifest(manifest);
  assert.equal(manifest.cases.length, 301);
  assert.equal(new Set(manifest.cases.map(c => c.model)).size, 149);
  assert.ok(manifest.cases.some(c => c.timeSeconds > 0));
  assert.ok(manifest.cases.every(c => !c.model.includes('ABeautifulGame')));
});
test('invalid manifests cannot traverse paths, reuse outputs, or sample negative time', () => {
  for (const mutate of [
    m => { m.cases[0].model = '../outside.glb'; },
    m => { m.cases[1].id = m.cases[0].id; },
    m => { m.cases[0].id = '../outside'; },
    m => { m.cases[0].timeSeconds = -1; },
    m => { m.cases[0].camera.far = 0; }
  ]) {
    const copy = structuredClone(manifest);
    mutate(copy);
    assert.throws(() => validateManifest(copy));
  }
  assert.throws(() => safePath(path.resolve('root'), '../root-sibling/file'));
});
test('animation captures hold the same camera for every pose of a scene', () => {
  for (const model of new Set(manifest.cases.map(c => c.model))) {
    const cases = manifest.cases.filter(c => c.model === model);
    for (const scene of new Set(cases.map(c => c.scene))) {
      const poses = cases.filter(c => c.scene === scene);
      assert.ok(poses.every(c => JSON.stringify(c.camera) === JSON.stringify(poses[0].camera)));
    }
  }
});
test('one image folder contains exactly the recorded masters and hashes', async () => {
  const directory = path.dirname(defaultManifest);
  const entries = await readdir(directory, { withFileTypes: true });
  assert.deepEqual(entries.filter(e => e.isDirectory()).map(e => e.name), ['images']);
  const run = JSON.parse(await readFile(path.join(directory, 'run.json'), 'utf8'));
  assert.equal(run.manifestSha256, sha256(await readFile(defaultManifest)));
  assert.deepEqual(run.sources, manifest.sources);
  const ids = manifest.cases.map(c => c.id).sort();
  assert.deepEqual(run.captures.map(c => c.id).sort(), ids);
  assert.deepEqual((await readdir(path.join(directory, 'images'))).sort(), ids.map(id => `${id}.png`));
  for (const capture of run.captures) {
    assert.equal(capture.status, 'ok');
    assert.equal(sha256(await readFile(path.join(directory, 'images', `${capture.id}.png`))), capture.sha256);
  }
});
test('focused recaptures retain other masters and their original renderer provenance', () => {
  const previous = { sources: manifest.sources, manifestSha256: 'original',
    browser: 'old browser', gpu: { renderer: 'old GPU' },
    captures: [{ id: 'first', status: 'ok', sha256: 'first hash' },
      { id: 'second', status: 'ok', sha256: 'second hash' }] };
  const retained = retainedCaptures(previous, manifest, 'original', ['first']);
  assert.deepEqual(retained, [{ ...previous.captures[1],
    capturedWith: { browser: previous.browser, gpu: previous.gpu } }]);
  assert.equal(previous.captures[1].capturedWith, undefined);
  const next = { ...previous, captures: retained, browser: 'new browser' };
  assert.deepEqual(retainedCaptures(next, manifest, 'original', []), retained);
  assert.throws(() => retainedCaptures(previous, manifest, 'changed', ['first']));
  assert.throws(() => retainedCaptures({ ...previous, sources: {} }, manifest, 'original', ['first']));
  assert.deepEqual(retainedCaptures(undefined, manifest, 'original', ['first']), []);
});
