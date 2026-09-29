import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import { pack } from '../../packages/cli/bin/platform.mjs';

const packed = await pack('extensions/web-search');
const pkg = JSON.parse(await fs.readFile(packed.output, 'utf8'));
const extension = vm.runInNewContext(pkg.source + '\nExtension.default', { URL });

async function query(id, input) {
  return extension.commands.find(command => command.id === id).query({ query: input });
}

test('unmatched text gets safe Google and Baidu web-search actions', async () => {
  const { items } = await query('web', 'Vectracast launcher');
  assert.deepEqual(Array.from(items, item => item.id), ['google', 'baidu']);
  assert.equal(items[0].actions[0].text, 'https://www.google.com/search?q=Vectracast%20launcher');
  assert.equal(items[1].actions[0].text, 'https://www.baidu.com/s?wd=Vectracast%20launcher');
  for (const item of items) {
    assert.equal(item.actions[0].type, 'url.open');
    assert.match(item.actions[0].text, /^https:\/\//);
  }
});

test('explicit engine keywords produce only that search provider', async () => {
  assert.deepEqual(Array.from((await query('google', 'Vectracast')).items, item => item.id), ['google']);
  assert.deepEqual(Array.from((await query('baidu', 'Vectracast')).items, item => item.id), ['baidu']);
});

test('website input offers site search and direct HTTPS open', async () => {
  const { items } = await query('web', 'https://example.com/docs');
  assert.deepEqual(Array.from(items, item => item.id), ['google', 'baidu', 'website']);
  assert.equal(items[0].actions[0].text, 'https://www.google.com/search?q=site%3Aexample.com');
  assert.equal(items[1].actions[0].text, 'https://www.baidu.com/s?wd=site%3Aexample.com');
  assert.equal(items[2].actions[0].text, 'https://example.com/docs');
  assert.equal((await query('web', 'example.com')).items[2].id, 'website');
});

test('long terms are rejected before an unsafe or oversized URL is returned', async () => {
  const { items } = await query('web', '中'.repeat(300));
  assert.equal(items.length, 1);
  assert.equal(items[0].id, 'url-too-long');
});
