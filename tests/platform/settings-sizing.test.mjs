import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

test('settings pages retain the general height regardless of plugin content, with compact About and screen limits', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'launcher-settings-sizing-'));
  try {
    fs.writeFileSync(path.join(dir, 'main.swift'), `
import Foundation
let result: [String: CGFloat] = [
 "width": SettingsSizing.width,
 "about": SettingsSizing.height(forPage: "about", body: 265, availableHeight: 900),
 "general": SettingsSizing.height(forPage: "general", body: 568, availableHeight: 900),
 "advanced": SettingsSizing.height(forPage: "advanced", body: 348, availableHeight: 900),
 "shortPlugin": SettingsSizing.height(forPage: "extensions", body: 300, availableHeight: 900),
 "longPlugin": SettingsSizing.height(forPage: "extensions", body: 1200, availableHeight: 900),
 "smallScreen": SettingsSizing.height(forPage: "extensions", body: 1200, availableHeight: 550)
]
print(String(data: try! JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
`);
    const binary = path.join(dir, 'check');
    const build = spawnSync('swiftc', ['apps/macos/Sources/SettingsSizing.swift', path.join(dir, 'main.swift'), '-o', binary], {encoding:'utf8', timeout:30000});
    assert.equal(build.status, 0, build.stderr);
    const run = spawnSync(binary, [], {encoding:'utf8', timeout:5000});
    assert.equal(run.status, 0, run.stderr);
    assert.deepEqual(JSON.parse(run.stdout), {width:1000, about:345, general:648, advanced:648, shortPlugin:648, longPlugin:648, smallScreen:510});
  } finally { fs.rmSync(dir, {recursive:true, force:true}); }
});
