import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { pack } from '../../packages/cli/bin/platform.mjs';

const app = path.resolve('build/Vectracast.app/Contents/MacOS/Vectracast');
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC', 'base64');

function fixture() {
  const root = fsSync.mkdtempSync(path.join(os.tmpdir(), 'vectracast-extension-icons-'));
  const directory = path.join(root, 'fixture');
  fsSync.mkdirSync(path.join(directory, 'src'), { recursive: true });
  fsSync.mkdirSync(path.join(directory, 'assets'));
  fsSync.writeFileSync(path.join(directory, 'assets', 'plugin.png'), png);
  fsSync.writeFileSync(path.join(directory, 'src', 'index.ts'), `
import { defineExtension, defineSearchCommand } from "@platform/sdk";
export default defineExtension({ commands: [defineSearchCommand({ id: "search", async query() { return { items: [] }; } })] });
`);
  const manifest = {
    manifestVersion: 1, id: 'local.icon-test', name: '图标测试', version: '1.0.0', description: 'fixture',
    runtime: 'standard-js', sdk: '0.1', icon: 'assets/plugin.png', entry: 'src/index.ts',
    commands: [{ id: 'search', title: '搜索', keywords: ['icontest'], icon: 'assets/plugin.png' }],
    permissions: {}, preferences: [],
  };
  fsSync.writeFileSync(path.join(directory, 'extension.json'), JSON.stringify(manifest));
  return { root, directory };
}

import fsSync from 'node:fs';

test('CLI packages referenced plugin and command images; host verifies and installs them', async () => {
  const { root, directory } = fixture();
  try {
    const built = await pack(directory);
    const pkg = JSON.parse(await fs.readFile(built.output, 'utf8'));
    assert.equal(pkg.manifest.icon, 'assets/plugin.png');
    assert.equal(pkg.manifest.commands[0].icon, 'assets/plugin.png');
    assert.equal(Buffer.from(pkg.resources['assets/plugin.png'], 'base64').compare(png), 0);
    const canonical = Object.keys(pkg.resources).sort().map(key => `${key}\0${pkg.resources[key]}\n`).join('');
    assert.equal(pkg.resourcesSha256, createHash('sha256').update(canonical).digest('hex'));

    const home = path.join(root, 'app-support');
    const env = { ...process.env, LAUNCHER_HOME: home };
    const installed = spawnSync(app, ['--install', built.output, '--accept-permissions'], { encoding: 'utf8', env });
    assert.equal(installed.status, 0, installed.stderr + installed.stdout);
    assert.match(installed.stdout, /Installed local.icon-test/);

    pkg.resourcesSha256 = '0'.repeat(64);
    const corrupt = path.join(root, 'corrupt.launcher-extension');
    await fs.writeFile(corrupt, JSON.stringify(pkg));
    const rejected = spawnSync(app, ['--install', corrupt, '--accept-permissions'], { encoding: 'utf8', env });
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr + rejected.stdout, /图标资源校验失败/);
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});

test('CLI rejects unsafe and missing packaged icon paths', async () => {
  const { root, directory } = fixture();
  try {
    const manifestPath = path.join(directory, 'extension.json');
    const manifest = JSON.parse(await fs.readFile(manifestPath, 'utf8'));
    manifest.icon = 'assets/../escape.png';
    await fs.writeFile(manifestPath, JSON.stringify(manifest));
    await assert.rejects(pack(directory), /icon/i);
    manifest.icon = 'assets/missing.png';
    await fs.writeFile(manifestPath, JSON.stringify(manifest));
    await assert.rejects(pack(directory), /ENOENT/);
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
