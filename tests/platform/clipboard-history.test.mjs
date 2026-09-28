import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { spawnSync } from 'node:child_process';
import { pack, validateManifest } from '../../packages/cli/bin/platform.mjs';
const built = await pack('extensions/clipboard-history');
const pkg = JSON.parse(fs.readFileSync(built.output));
const extension = vm.runInNewContext(pkg.source + '\nExtension.default', {});
const entries = [
 {id:'a',text:'第一行\n第二行',source:'Notes',timestamp:1000},
 {id:'b',text:'Hello  Launcher',source:'Safari',timestamp:2000},
];
async function query(query, history=entries, filter='all') { return JSON.parse(JSON.stringify(await extension.commands[0].query({query,filter,clipboard:{history:async()=>history}}))).items; }
test('clipboard plugin searches text and app, sorts recent first, copies full original text', async()=>{
 const rows=await query('');assert.deepEqual(rows.map(x=>x.id),['b','a']);
 assert.equal(rows[1].title,'第一行 第二行');assert.equal(rows[1].preview.text,'第一行\n第二行');assert.equal(rows[1].actions[0].type,'clipboard.history.copy');
 assert.equal(rows[1].actions[2].text,'a');assert.equal(rows[1].actions[3].type,'clipboard.history.clear');
 assert.deepEqual((await query('HELLO safari')).map(x=>x.id),['b']);
 assert.equal((await query('missing'))[0].title,'没有匹配的记录');
 assert.equal((await query('',[]))[0].actions.length,0);
 const many=Array.from({length:200},(_,i)=>({...entries[0],id:String(i),timestamp:i}));
 assert.equal((await query('',many)).length,40);
 assert.ok((await query('',[{...entries[0],text:'a'.repeat(200)}]))[0].title.endsWith('…'));
});
test('detail metadata, image handles and content filters remain plugin-owned',async()=>{
 const history=[...entries,{id:'pic',text:'',kind:'image',width:640,height:480,byteCount:1024,source:'Preview',timestamp:Date.now()},{id:'url',text:'https://example.com',source:'Safari',timestamp:3000}];
 const images=await query('',history,'image');assert.equal(images.length,1);assert.equal(images[0].title,'图片 (640×480)');assert.deepEqual(images[0].preview,{historyImageID:'pic'});
 assert.equal(images[0].metadata.find(x=>x.label==='大小').value,'1.0 KB');assert.equal(images[0].group,'今天');
 assert.deepEqual((await query('',history,'link')).map(x=>x.id),['url']);
 assert.deepEqual((await query('',history,'text')).map(x=>x.id),['b','a']);
 assert.equal((await query('',history,'text'))[1].metadata.find(x=>x.label==='字符数').value,'7');
});
test('clipboard manifest declares history access but no network or implicit root access',()=>{
 validateManifest(pkg.manifest);assert.deepEqual(pkg.manifest.permissions,{clipboard:['history','history-images','write','paste']});
 assert.notEqual(pkg.manifest.commands[0].inputMode,'query');
 assert.throws(()=>validateManifest({...pkg.manifest,permissions:{clipboard:['read-anything']}}));
});
test('native history persistence, deduplication, expiry, limits, private files, capture gate and sensitive markers',()=>{
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'launcher-history-'));
 try {
  fs.writeFileSync(path.join(directory,'main.swift'),`
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let url = root.appendingPathComponent("history/data.json")
let now = Date()
let history = try ClipboardHistoryArchive(url: url, now: now)
try history.append(text: "alpha", source: "Notes", now: now)
try history.append(text: "beta", source: "Safari", now: now.addingTimeInterval(1))
try history.append(text: "alpha", source: "Terminal", now: now.addingTimeInterval(2))
assert(history.entries.count == 2 && history.entries[0].text == "alpha")
let reopened = try ClipboardHistoryArchive(url: url, now: now.addingTimeInterval(3))
assert(reopened.entries.count == 2 && reopened.entries[0].source == "Terminal")
let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
assert((attrs[.posixPermissions] as! NSNumber).intValue == 384)
try reopened.remove(reopened.entries[0].id); assert(reopened.entries.count == 1)
try reopened.append(text: String(repeating: "x", count: 10001), source: "Test"); assert(reopened.entries.count == 1)
for i in 0..<220 { try reopened.append(text: "item \\(i)", source: "Test", now: now.addingTimeInterval(Double(i))) }
assert(reopened.entries.count == 200)
let expired = try ClipboardHistoryArchive(url: url, now: now.addingTimeInterval(ClipboardHistoryArchive.lifetime + 300))
assert(expired.entries.isEmpty)
try expired.append(text: "new", source: "Test"); try expired.clear()
let cleared = try ClipboardHistoryArchive(url: url); assert(cleared.entries.isEmpty)
for i in 0..<80 { try expired.append(text: String(repeating: "\\u{01}", count: 9900) + String(i), source: "Test") }
let stored = try Data(contentsOf: url); assert(stored.count < 510000)
let bounded = try ClipboardHistoryArchive(url: url); assert(!bounded.entries.isEmpty)
let imageArchive = try ClipboardHistoryArchive(url: root.appendingPathComponent("images/index.json"))
try imageArchive.appendImage(png: Data([1,2,3]), width: 40, height: 20, source: "Test")
let imageEntry = imageArchive.entries[0]; let asset = imageArchive.imageURL(for: imageEntry)!
assert(FileManager.default.fileExists(atPath: asset.path)); assert(imageEntry.metadata["imageFile"] == nil)
try imageArchive.appendImage(png: Data([1,2,3]), width: 40, height: 20, source: "Test")
assert(imageArchive.entries.count == 1)
let imageReopened = try ClipboardHistoryArchive(url: imageArchive.url); assert(imageReopened.entries[0].contentType == "image")
try imageReopened.remove(imageReopened.entries[0].id); assert(!FileManager.default.fileExists(atPath: asset.path))
try imageReopened.appendImage(png: Data([4]), width: 40, height: 20, source: "Test")
let removedAsset = imageReopened.imageURL(for: imageReopened.entries[0])!; try imageReopened.clear(); assert(!FileManager.default.fileExists(atPath: removedAsset.path))
var gate = ClipboardCaptureGate()
assert(gate.recipients(changeCount: 1, enabled: []).isEmpty)
assert(gate.recipients(changeCount: 2, enabled: ["a"]).isEmpty)
assert(gate.recipients(changeCount: 3, enabled: ["a"]) == ["a"])
assert(gate.recipients(changeCount: 4, enabled: []).isEmpty)
assert(gate.recipients(changeCount: 5, enabled: ["a"]).isEmpty)
assert(gate.recipients(changeCount: 6, enabled: ["a", "b"]) == ["a"])
assert(gate.recipients(changeCount: 6, enabled: ["a", "b"]).isEmpty)
assert(!ClipboardCaptureGate.accepts(types: ["org.nspasteboard.ConcealedType"], sourceID: "test"))
assert(!ClipboardCaptureGate.accepts(types: ["org.nspasteboard.TransientType"], sourceID: "test"))
assert(!ClipboardCaptureGate.accepts(types: [], sourceID: "com.agilebits.onepassword7"))
assert(ClipboardCaptureGate.accepts(types: ["public.utf8-plain-text"], sourceID: "com.apple.Notes"))
print("passed")
`);
  const executable=path.join(directory,'check');
  const build=spawnSync('swiftc',['apps/macos/Sources/ClipboardHistoryArchive.swift',path.join(directory,'main.swift'),'-o',executable],{encoding:'utf8',timeout:30000});
  assert.equal(build.status,0,build.stderr);
  const result=spawnSync(executable,[directory],{encoding:'utf8',timeout:15000});assert.equal(result.status,0,result.stderr);
 } finally {fs.rmSync(directory,{recursive:true,force:true})}
});
