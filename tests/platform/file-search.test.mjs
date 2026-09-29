import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {pack,validateManifest} from '../../packages/cli/bin/platform.mjs';
const packed=await pack('extensions/file-search');
const pkg=JSON.parse(await fs.readFile(packed.output,'utf8'));
const plugin=vm.runInNewContext(pkg.source+'\nExtension.default',{});
const entry=(id,name,kind='document',modified=1)=>({id,name,kind,modified,path:'/Users/test/Documents/'+id+'/'+name,size:123});
const invoke=async(query,files=[],filter='all',limited=false)=>JSON.parse(JSON.stringify(await plugin.commands[0].query({query,filter,files:{search:async(text,kind)=>{assert.equal(text,query.trim());assert.equal(kind,filter);return {files,limited,timedOut:limited}}}})));
test('file search enters without requesting an empty index scan',async()=>{
 const result=await plugin.commands[0].query({query:' ',files:{search:()=>{throw Error('must not search')}}});
 assert.match(result.items[0].title,/输入文件名/);assert.equal(result.items[0].actions.length,0);
 assert.equal(pkg.manifest.commands[0].presentation,'list');assert.equal(pkg.manifest.commands[0].acceptsEmptyQuery,true);
});
test('file search ranks exact/prefix matches, filters types and binds file actions to issued IDs',async()=>{
 const files=[entry('a','Old Report.pdf'),entry('b','Report.pdf','document',2),entry('c','Report.pdf','document',4),entry('d','Report.pdf','image',9)];
 const rows=(await invoke('report.pdf',files,'document')).items;
 assert.deepEqual(rows.map(x=>x.id),['c','b','a']);
 for(const row of rows){assert.equal(row.actions[0].text,row.fileID);assert.equal(row.actions[1].text,row.fileID);assert.equal(row.actions[2].text,row.subtitle);}
 const cn=(await invoke('合同',[entry('cn','合同.docx'),entry('en','other.txt')])).items;assert.equal(cn[0].id,'cn');
 assert.equal((await invoke('CAFE',[entry('accent','Café.md')])).items[0].id,'accent');
});
test('file search bounds results and distinguishes unavailable/empty results',async()=>{
 const rows=(await invoke('file',Array.from({length:160},(_,i)=>entry(''+i,'file'+i)))).items;assert.equal(rows.length,50);assert.match(rows[0].group,/50/);
 assert.match((await invoke('missing')).items[0].title,/没有找到/);
 assert.match((await invoke('missing',[],'all',true)).items[0].title,/暂未完成/);
 assert.equal((await invoke('x'.repeat(201))).items[0].actions.length,0);
});
test('file permissions reject unsupported access and require search before open',()=>{
 validateManifest(pkg.manifest);
 for(const files of [['open'],['read'],['shell'],'search'])assert.throws(()=>validateManifest({...pkg.manifest,permissions:{files}}));
});
test('native file scope rejects hidden/library/outside/symlink files and stops cancelled queries',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'vectracast-file-scope-'));
 try{
 const source=path.join(dir,'main.swift');const binary=path.join(dir,'scope');
 await fs.writeFile(source,`import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
func check(_ value: Bool) { if !value { fatalError("scope check") } }
try fm.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
try fm.createDirectory(at: root.appendingPathComponent("Test.app/Contents"), withIntermediateDirectories: true)
let normal=root.appendingPathComponent("合同.txt")
try Data("fixture".utf8).write(to: normal)
for name in [".secret", "Library/secret", "Test.app/Contents/secret"] {try Data().write(to:root.appendingPathComponent(name))}
try fm.createSymbolicLink(atPath:root.appendingPathComponent("linked.txt").path,withDestinationPath:normal.path)
check(FileSearch.allowedURL(normal,root:root) != nil)
for name in [".secret","Library/secret","Test.app/Contents/secret","linked.txt","missing"] {check(FileSearch.allowedURL(root.appendingPathComponent(name),root:root) == nil)}
check(FileSearch.allowedURL(URL(fileURLWithPath:"/etc/hosts"),root:root) == nil)
check(FileSearch.kind(normal,directory:false) == "document")
let document = [NSMetadataItemFSNameKey: "README.md", NSMetadataItemPathKey: normal.path, "kMDItemContentType": "net.daringfireball.markdown"]
check(!FileSearch.predicate(text:"README",kind:"image").evaluate(with:document))
check(FileSearch.predicate(text:"README",kind:"document").evaluate(with:document))
check(!FileSearch.predicate(text:"README OR 1=1",kind:"all").evaluate(with:document))
let search=FileSearch(); var called=false
search.start(text:"README",filter:"all"){_,_,_ in called=true}
search.cancel()
RunLoop.main.run(until:Date().addingTimeInterval(0.1))
check(!called)
print("PASS")
`);
 const build=spawnSync('swiftc',['apps/macos/Sources/FileSearch.swift',source,'-o',binary],{encoding:'utf8'});assert.equal(build.status,0,build.stderr);
 const run=spawnSync(binary,[dir],{encoding:'utf8'});assert.equal(run.status,0,run.stderr);assert.match(run.stdout,/PASS/);
 }finally{await fs.rm(dir,{recursive:true,force:true})}
});
