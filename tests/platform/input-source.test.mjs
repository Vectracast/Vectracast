import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
test('input source restoration respects manual changes and failed selection',()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'launcher-input-'));
 try {
  fs.writeFileSync(path.join(dir,'main.swift'),`
import Foundation
let session = InputSourceSession()
var current = "chinese", calls = 0
func select(_ id: String) -> Bool { calls += 1; if id == "missing" { return false }; current = id; return true }
assert(session.activate(nil, current: { current }, select: select)); assert(calls == 0)
assert(session.activate("english", current: { current }, select: select)); assert(current == "english")
assert(session.activate("english", current: { current }, select: select)); assert(calls == 1)
session.restore(current: { current }, select: select); assert(current == "chinese")
assert(session.activate("english", current: { current }, select: select)); current = "manual"
session.restore(current: { current }, select: select); assert(current == "manual")
assert(!session.activate("missing", current: { current }, select: select))
session.restore(current: { current }, select: select); assert(current == "manual")
assert(session.activate("manual", current: { current }, select: select)); current = "new-manual"
session.restore(current: { current }, select: select); assert(current == "new-manual")
print("passed")
`);
  const binary=path.join(dir,'check'); const build=spawnSync('swiftc',['apps/macos/Sources/InputSourceSession.swift',path.join(dir,'main.swift'),'-o',binary],{encoding:'utf8',timeout:30000});assert.equal(build.status,0,build.stderr);
  const run=spawnSync(binary,[],{encoding:'utf8',timeout:5000});assert.equal(run.status,0,run.stderr);
 } finally {fs.rmSync(dir,{recursive:true,force:true})}
});
