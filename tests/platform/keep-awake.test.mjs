import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { spawnSync } from 'node:child_process';
import { pack, validateManifest } from '../../packages/cli/bin/platform.mjs';

const packed = await pack('extensions/keep-awake');
const pkg = JSON.parse(fs.readFileSync(packed.output, 'utf8'));
const extension = vm.runInNewContext(pkg.source + '\nExtension.default', {});
const query = (state, input = '') => extension.commands[0].query({ query: input, power: { status: async () => state } });

test('keep-awake status never mutates power and only offers actions appropriate to ownership', async () => {
  const normal = (await query({ sleepDisabled: false, canRestore: false, powerSource: 'battery' })).items;
  assert.equal(normal[0].actions[0].type, 'power.refresh');
  assert.match(normal[0].subtitle, /电池/);
  assert.ok(normal.some(row => row.id === 'enable'));
  assert.ok(!normal.some(row => row.id === 'restore'));
  assert.match(normal.find(row => row.id === 'notice').detail, /卸载插件不会恢复/);
  const active = (await query({ sleepDisabled: true, canRestore: true, powerSource: 'ac' })).items;
  assert.ok(active.some(row => row.id === 'restore'));
  assert.ok(!active.some(row => row.id === 'enable'));
  const external = (await query({ sleepDisabled: true, canRestore: false, powerSource: 'ac' })).items;
  assert.ok(external.some(row => row.id === 'external'));
  assert.ok(external.every(row => row.actions.every(action => !['power.enable', 'power.restore'].includes(action.type))));
  const interrupted = (await query({ sleepDisabled: false, canRestore: true, powerSource: 'ac' })).items;
  assert.ok(interrupted.some(row => row.id === 'restore'));
});

test('power permission schema rejects arbitrary access and manage without read', () => {
  validateManifest(pkg.manifest);
  for (const power of [['manage'], ['read', 'shell'], 'read']) {
    assert.throws(() => validateManifest({ ...pkg.manifest, permissions: { power } }), /power/);
  }
});

test('keep-awake displays read errors with a retry action', async () => {
  const result = await extension.commands[0].query({ query: '', power: { status: async () => { throw 'unavailable'; } } });
  assert.equal(result.items[0].actions[0].type, 'power.refresh');
  assert.equal(result.items[0].subtitle, 'unavailable');
});

test('native power service preserves recovery through restart, cancellation and failed verification', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'vectracast-power-test-'));
  try {
    fs.writeFileSync(path.join(directory, 'main.swift'), `
import Foundation
func check(_ value: Bool) { assert(value) }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var disabled = false
var writes: [Bool] = []
var failure = false
var ignoreWrite = false
let read: ([String]) throws -> String = { args in
    args == ["-g", "batt"] ? "Now drawing from 'Battery Power'" : "System-wide power settings:\\n SleepDisabled \\(disabled ? 1 : 0)\\nCurrently in use:\\n sleep 1"
}
let write: (Bool) throws -> Void = { value in
    writes.append(value)
    if failure { throw LauncherError("cancelled") }
    if !ignoreWrite { disabled = value }
}
func mustFail(_ operation: () throws -> Void) {
    do { try operation(); fatalError("expected failure") } catch {}
}
let service = PowerControl(root: root, read: read, write: write)
check(try !PowerControl.sleepDisabled("System-wide power settings:\\nCurrently in use:\\n sleep 1"))
mustFail { _ = try PowerControl.sleepDisabled("truncated output") }
mustFail { _ = try PowerControl.sleepDisabled("System-wide power settings:\\n SleepDisabled nope\\nCurrently in use:") }
let initial = try service.status()
assert(!initial.sleepDisabled && !initial.canRestore && initial.powerSource == "battery" && writes.isEmpty)
mustFail { try service.perform("power.arbitrary") }
mustFail { try service.perform("power.restore") }
assert(writes.isEmpty)
disabled = true
mustFail { try service.perform("power.enable") }
assert(writes.isEmpty)
disabled = false
try service.perform("power.enable")
assert(disabled && writes == [true])
let restarted = PowerControl(root: root, read: read, write: write)
check(try restarted.status().canRestore)
try restarted.perform("power.enable")
assert(writes == [true])
try restarted.perform("power.restore")
assert(!disabled && writes == [true, false])
check(try !restarted.status().canRestore)
failure = true
mustFail { try service.perform("power.enable") }
check(try service.status().canRestore)
failure = false
try service.perform("power.restore")
check(try !service.status().canRestore)
ignoreWrite = true
mustFail { try service.perform("power.enable") }
check(try service.status().canRestore)
ignoreWrite = false
try service.perform("power.restore")
let saved = root.appendingPathComponent("power-control/snapshot.json")
try Data("invalid backup".utf8).write(to: saved)
let count = writes.count
mustFail { try service.perform("power.enable") }
assert(writes.count == count)
print("PASS: only injected writes were used")
`);
    const binary = path.join(directory, 'check');
    const compile = spawnSync('swiftc', ['apps/macos/Sources/Models.swift', 'apps/macos/Sources/PowerControl.swift', path.join(directory, 'main.swift'), '-o', binary], { encoding: 'utf8' });
    assert.equal(compile.status, 0, compile.stderr);
    const run = spawnSync(binary, [path.join(directory, 'state')], { encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr + run.stdout);
    assert.match(run.stdout, /PASS/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
