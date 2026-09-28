import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

test('action state isolates plugins, survives restart and validates keys and shortcuts',()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'launcher-action-state-'));
 try {
  fs.writeFileSync(path.join(dir,'main.swift'),`
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let state = ExtensionActionState(root: root)
assert(try state.flags("test.one").isEmpty)
assert(try state.toggle("test.one", key:"favorite:test.app"))
assert(try ExtensionActionState(root: root).flags("test.one")["favorite:test.app"] == true)
assert(try state.flags("test.two").isEmpty)
assert(try !state.toggle("test.one", key:"favorite:test.app"))
assert(try state.flags("test.one").isEmpty)
do { _ = try state.toggle("../escape", key:"key"); fatalError("namespace traversal") } catch {}
do { _ = try state.toggle("test.one", key:""); fatalError("empty key") } catch {}
assert(!ExtensionActionState.validKey(String(repeating:"x",count:257)))
assert(ActionShortcut.isValid(.init(key:"i", modifiers:["option","command"])))
assert(ActionShortcut.isValid(.init(key:"return", modifiers:[])))
assert(!ActionShortcut.isValid(.init(key:"i", modifiers:[])))
assert(!ActionShortcut.isValid(.init(key:"k", modifiers:["bogus"])))
assert(!ActionShortcut.isValid(.init(key:"k", modifiers:["command","command"])))
print("PASS")
`.replaceAll('assert(try ', 'assert(try! '));
 const binary=path.join(dir,'check');
 const build=spawnSync('swiftc',['apps/macos/Sources/Models.swift','apps/macos/Sources/ExtensionActionState.swift',path.join(dir,'main.swift'),'-o',binary],{encoding:'utf8',timeout:30000});
 assert.equal(build.status,0,build.stderr);
 const run=spawnSync(binary,[dir],{encoding:'utf8',timeout:10000});assert.equal(run.status,0,run.stderr);
 } finally { fs.rmSync(dir,{recursive:true,force:true}); }
});
