import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

test('launcher placement restores per screen, reserves result space and only snaps empty searches', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'launcher-placement-'));
  try {
    fs.writeFileSync(path.join(dir, 'main.swift'), `
import Foundation
import CoreGraphics
let area = CGRect(x: -1920, y: 40, width: 1920, height: 1040)
let size = CGSize(width: 774, height: 100)
let initial = LauncherPlacement.restore(nil, size: size, in: area)
assert(initial.midX == area.midX)
assert(abs(area.maxY - initial.maxY - 291.2) < 0.01)
let near = initial.offsetBy(dx: 9, dy: -10)
let (snapped, state) = LauncherPlacement.snap(near, in: area, enabled: true, previous: .init())
assert(snapped == initial && state.horizontal && state.vertical)
let (plain, disabled) = LauncherPlacement.snap(near, in: area, enabled: false, previous: state)
assert(plain == near && !disabled.horizontal && !disabled.vertical)
let (_, held) = LauncherPlacement.snap(initial.offsetBy(dx: 20, dy: 20), in: area, enabled: true, previous: state)
assert(held.horizontal && held.vertical)
let (_, released) = LauncherPlacement.snap(initial.offsetBy(dx: 30, dy: 30), in: area, enabled: true, previous: held)
assert(!released.horizontal && !released.vertical)
let offscreen = LauncherPlacement.constrain(initial.offsetBy(dx: 4000, dy: -3000), in: area)
assert(offscreen.maxX <= area.maxX - 16)
assert(offscreen.maxY - 474 >= area.minY + 16)
let custom = initial.offsetBy(dx: 80, dy: 45)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let store = LauncherPositionStore(root: root)
store.save(LauncherPlacement.anchor(for: custom, in: area), for: "external")
let restored = LauncherPositionStore(root: root)
assert(restored.anchor(for: "internal") == nil)
let frame = LauncherPlacement.restore(restored.anchor(for: "external"), size: size, in: area)
assert(abs(frame.minX - custom.minX) < 0.01 && abs(frame.maxY - custom.maxY) < 0.01)
let expanded = LauncherPlacement.restore(restored.anchor(for: "external"), size: CGSize(width: 774, height: 474), in: area)
assert(abs(expanded.maxY - frame.maxY) < 0.01)
let smaller = CGRect(x: 0, y: 0, width: 1024, height: 600)
let migrated = LauncherPlacement.restore(restored.anchor(for: "external"), size: CGSize(width: 774, height: 474), in: smaller)
assert(smaller.contains(migrated))
try Data("corrupt".utf8).write(to: root.appendingPathComponent("launcher-position.json"))
assert(LauncherPositionStore(root: root).anchor(for: "external") == nil)
print("placement checks passed")
`);
    const binary = path.join(dir, 'check');
    const build = spawnSync('swiftc', ['apps/macos/Sources/LauncherPlacement.swift', path.join(dir, 'main.swift'), '-o', binary], {encoding:'utf8', timeout:30000});
    assert.equal(build.status, 0, build.stderr);
    const run = spawnSync(binary, [dir], {encoding:'utf8', timeout:5000});
    assert.equal(run.status, 0, run.stderr);
  } finally { fs.rmSync(dir, {recursive:true, force:true}); }
});
