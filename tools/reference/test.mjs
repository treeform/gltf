import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { defaultManifest, validateManifest, safePath } from './common.mjs';

const manifest = JSON.parse(await readFile(defaultManifest, 'utf8'));
test('the fast suite has five distinct models and includes later animation poses', () => {
  validateManifest(manifest);
  assert.equal(manifest.cases.length, 5);
  assert.equal(new Set(manifest.cases.map(c => c.model)).size, 5);
  assert.equal(manifest.cases.filter(c => c.timeSeconds > 0).length, 3);
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
test('the expanded animation suite holds the same camera for every pose of a model', async () => {
  const expanded = JSON.parse(await readFile(path.join(path.dirname(defaultManifest), 'manifest-25.json'), 'utf8'));
  validateManifest(expanded);
  assert.equal(expanded.cases.length, 25);
  for (const model of new Set(expanded.cases.map(c => c.model))) {
    const cases = expanded.cases.filter(c => c.model === model);
    assert.ok(cases.every(c => JSON.stringify(c.camera) === JSON.stringify(cases[0].camera)));
  }
});
