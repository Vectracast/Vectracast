import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { pack } from '../../packages/cli/bin/platform.mjs';

const binary = path.resolve('build/Vectracast.app/Contents/MacOS/Vectracast');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'launcher-tests-'));
process.on('exit', () => fs.rmSync(root, {recursive:true, force:true}));
const base = JSON.parse(fs.readFileSync('extensions/text-tools/extension.json', 'utf8'));
const run = (home, ...args) => spawnSync(binary, args, {env:{...process.env, LAUNCHER_HOME:path.join(root,home)}, encoding:'utf8', timeout:22000});
function fixture({id='test.sample', version='1.0.0', keywords=['test'], source='var Extension={default:{commands:[{id:"convert",query:async ctx=>({items:[{id:"one",title:ctx.query,actions:[]}]})}]}};', permissions={}}={}) {
  new Function(source); // Catch syntax mistakes in test fixtures before invoking the real runtime.
  const manifest = {...base,id,version,permissions,commands:[{...base.commands[0],id:"convert",keywords}]};
  const file=path.join(root, `${id}-${version}-${Math.random()}.launcher-extension`);
  fs.writeFileSync(file,JSON.stringify({format:1,manifest,source,sha256:createHash('sha256').update(source).digest('hex')})); return file;
}
function install(home, file, ...args) { return run(home,'--install',file,...args); }
function good(result) { assert.equal(result.status,0,result.stderr+result.stdout); return result.stdout; }
function bad(result, pattern) { assert.notEqual(result.status,0); assert.match(result.stderr+result.stdout,pattern); }

test('XPC sandbox denies external file read/write and direct network',()=>{
 const p=JSON.parse(good(run('sandbox','--probe'))); assert.equal(p.readDenied,true);assert.equal(p.writeDenied,true);assert.equal(p.networkDenied,true);assert.ok([1,13].includes(p.networkError), 'Socket access must fail with EPERM/EACCES, not a DNS or connection error');
});
test('real SDK bundle runs in XPC and returns copy actions',async()=>{
 const p=await pack('extensions/text-tools'); good(install('query',p.output,'--accept-permissions'));
 const rows=JSON.parse(good(run('query','--query','local.text-tools','transform','Hello World'))).items;
 assert.equal(rows[0].title,'HELLO WORLD');assert.equal(rows[1].actions[0].text,'hello world');
});
test('backup migrates older preferences, restores configuration and rejects secrets or conflicting aliases',()=>{
 const home='backup'; const file=fixture(); const pkg=JSON.parse(fs.readFileSync(file));
 pkg.manifest.preferences=[{name:'theme',title:'Theme',type:'text',required:false},{name:'token',title:'Token',type:'secret',required:false}];
 fs.writeFileSync(file,JSON.stringify(pkg)); good(install(home,file,'--accept-permissions'));
 const prefFile=path.join(root,home,'preferences.json');
 const original=JSON.parse(good(run(home,'--preferences'))); original.shortcut={keyCode:49,modifiers:256,key:'Space'}; original.aliases={'test.sample/convert':'custom'};
 fs.writeFileSync(prefFile,JSON.stringify(original));
 assert.equal(JSON.parse(good(run(home,'--preferences'))).shortcut.modifiers,256);
 const exported=path.join(root,'exported.json');good(run(home,'--backup-export',exported));
 const backup=JSON.parse(fs.readFileSync(exported));assert.equal(backup.format,1);assert.equal(backup.plugins[0].version,'1.0.0');
 backup.preferences.searchSensitivity='low';backup.plugins[0].preferences={theme:'dark'};backup.plugins[0].enabled=false;
 fs.writeFileSync(exported,JSON.stringify(backup));const result=JSON.parse(good(run(home,'--backup-import',exported,'--apply')));
 assert.ok(fs.existsSync(result.recovery));assert.equal(JSON.parse(good(run(home,'--preferences'))).searchSensitivity,'low');
 assert.equal(JSON.parse(good(run(home,'--list')))[0].enabled,false);
 good(run(home,'--backup-export',exported));const roundtrip=JSON.parse(fs.readFileSync(exported));assert.deepEqual(roundtrip.plugins[0].preferences,{theme:'dark'});
 roundtrip.plugins[0].preferences.token='FAKE_TEST_SECRET';fs.writeFileSync(exported,JSON.stringify(roundtrip));bad(run(home,'--backup-import',exported,'--apply'),/密钥/);
 assert.equal(JSON.parse(good(run(home,'--list')))[0].enabled,false);
 roundtrip.plugins[0].preferences={theme:'dark'};roundtrip.preferences.commandShortcuts={'test.sample/convert':roundtrip.preferences.shortcut};
 fs.writeFileSync(exported,JSON.stringify(roundtrip));bad(run(home,'--backup-import',exported,'--apply'),/快捷键/);
 roundtrip.preferences.commandShortcuts={};roundtrip.format=99;fs.writeFileSync(exported,JSON.stringify(roundtrip));bad(run(home,'--backup-import',exported,'--apply'),/格式/);
 // Conflicts are validated before either the database or preferences is changed.
 good(install(home,fixture({id:'test.other',keywords:['other']}),'--accept-permissions'));
 roundtrip.format=1;roundtrip.plugins[0].enabled=true;roundtrip.preferences.aliases={'test.sample/convert':'other'};
 fs.writeFileSync(exported,JSON.stringify(roundtrip));bad(run(home,'--backup-import',exported,'--apply'),/冲突/);
 roundtrip.preferences.aliases={};roundtrip.plugins[0].version='9.0.0';fs.writeFileSync(exported,JSON.stringify(roundtrip));
 assert.deepEqual(JSON.parse(good(run(home,'--backup-import',exported,'--apply'))).skipped,['test.sample v9.0.0']);
});
test('search sensitivity reaches the SDK through the real XPC runtime',()=>{
 const home='sdk-search';good(install(home,fixture({source:'var Extension={default:{commands:[{id:"convert",query:async ctx=>({items:[{id:"one",title:ctx.search.sensitivity,actions:[]}]})}]}};'}),'--accept-permissions'));
 const prefs=JSON.parse(good(run(home,'--preferences')));prefs.searchSensitivity='high';fs.writeFileSync(path.join(root,home,'preferences.json'),JSON.stringify(prefs));
 assert.equal(JSON.parse(good(run(home,'--query','test.sample','convert','x'))).items[0].title,'high');
});
test('installation enforces digest, unknown permissions and explicit permission acceptance',()=>{
 const p=fixture({permissions:{clipboard:['write']}});
 bad(install('validate',p),/权限/); good(install('validate',p,'--accept-permissions'));
 const data=JSON.parse(fs.readFileSync(p)); data.source+=' ';fs.writeFileSync(p,JSON.stringify(data));bad(install('validate',p,'--accept-permissions'),/损坏/);
 bad(install('validate',fixture({id:'test.unknown',permissions:{shell:true}}),'--accept-permissions'),/权限/);
});
test('updates, immutable releases, permission growth and rollback',()=>{
 good(install('update',fixture(),'--accept-permissions'));
 bad(install('update',fixture({source:'var Extension={};'}),'--accept-permissions'),/相同版本/);
 const next=fixture({version:'1.1.0',permissions:{network:['https://example.com']}});
 bad(install('update',next),/权限/);good(install('update',next,'--accept-permissions'));
 good(run('update','--rollback','test.sample'));
 assert.equal(JSON.parse(good(run('update','--list')))[0].version,'1.0.0');
});
test('keyword conflicts are rejected on install and rollback',()=>{
 good(install('conflict',fixture({keywords:['old']}),'--accept-permissions'));
 good(install('conflict',fixture({version:'1.1.0',keywords:['new']}),'--accept-permissions'));
 good(install('conflict',fixture({id:'test.other',keywords:['old']}),'--accept-permissions'));
 bad(run('conflict','--rollback','test.sample'),/冲突/);
 bad(install('conflict',fixture({id:'test.third',keywords:['new']}),'--accept-permissions'),/冲突/);
});
test('broker denies undeclared network, secret and query-time clipboard access',()=>{
 for (const [name,query,pattern] of [
  ['network','await ctx.network.fetch("https://example.com")',/网络地址/],
  ['secret','await ctx.secrets.get("undeclared")',/密钥/],
  ['clipboard','await __rpc("clipboard.write",{text:"not allowed"})',/查询阶段/],
 ]) {
  const source=`var Extension={default:{commands:[{id:"convert",query:async ctx=>{${query};return {items:[]}}}]}};`;
  good(install(name,fixture({source}),'--accept-permissions'));
  bad(run(name,'--query','test.sample','convert','test'),pattern);
 }
});
test('host removes unsupported actions and forged application paths',()=>{
 const source='var Extension={default:{commands:[{id:"convert",query:async()=>({items:[{id:"one",title:"safe",applicationPath:"/Applications/Terminal.app",extensionID:"other",actions:[{id:"bad",title:"Run",type:"shell"},{id:"copy",title:"Copy",type:"clipboard.copy",text:"x"}]}]})}]}};';
 good(install('sanitize',fixture({source}),'--accept-permissions'));
 const rows=JSON.parse(good(run('sanitize','--query','test.sample','convert','x'))).items;
 assert.deepEqual(rows[0].actions,[]);assert.equal(rows[0].applicationPath,undefined);assert.equal(rows[0].extensionID,'test.sample');
});
test('watchdog interrupts a synchronous infinite loop; subsequent runtime works',()=>{
 good(install('watchdog',fixture({source:'while(true){}'}),'--accept-permissions'));
 const start=Date.now();bad(run('watchdog','--query','test.sample','convert','x'),/超时|中断/);assert.ok(Date.now()-start<20000);
 good(install('watchdog',fixture({version:'1.0.1'}),'--accept-permissions'));
 const rows=JSON.parse(good(run('watchdog','--query','test.sample','convert','recovered'))).items;assert.equal(rows[0].title,'recovered');
});
test('calculator extension executes in real XPC and participates in unprefixed search',async()=>{
 const p=await pack('extensions/calculator'); good(install('calc',p.output,'--accept-permissions'));
 for (const [input,expected] of [['12 ×（100）＋50','1250'],['0xff03','65283'],['9007199254740993+1','9007199254740994']]) {
  const rows=JSON.parse(good(run('calc','--implicit-query',input))).items;
  assert.equal(rows[0].title,expected);assert.equal(rows[0].extensionID,'local.calculator');assert.equal(rows[0].actions[0].text,expected);
 }
 assert.equal(JSON.parse(good(run('calc','--implicit-query','Safari'))).items.length,0);
 const invalid=JSON.parse(good(run('calc','--implicit-query','1/0'))).items;assert.match(invalid[0].title,/不能除以/);assert.deepEqual(invalid[0].actions,[]);
});
test('query input mode accepts empty keywords, requires renewed consent, and merges namespaced results',()=>{
 const first=fixture(); good(install('implicit',first,'--accept-permissions'));
 const change=fixture({version:'1.1.0'});const pkg=JSON.parse(fs.readFileSync(change));pkg.manifest.commands[0].inputMode='query';pkg.manifest.commands[0].keywords=[];fs.writeFileSync(change,JSON.stringify(pkg));
 bad(install('implicit',change),/权限/);good(install('implicit',change,'--accept-permissions'));
 const second=fixture({id:'test.second',keywords:[]});const pkg2=JSON.parse(fs.readFileSync(second));pkg2.manifest.commands[0].inputMode='query';fs.writeFileSync(second,JSON.stringify(pkg2));good(install('implicit',second,'--accept-permissions'));
 const rows=JSON.parse(good(run('implicit','--implicit-query','sample'))).items;
 assert.equal(rows.length,2);assert.equal(new Set(rows.map(x=>x.id)).size,2);assert.ok(rows.every(x=>x.title==='sample'));
 const unknown=fixture({id:'test.unknownmode'});const invalid=JSON.parse(fs.readFileSync(unknown));invalid.manifest.commands[0].inputMode='typo';fs.writeFileSync(unknown,JSON.stringify(invalid));bad(install('implicit',unknown,'--accept-permissions'),/命令/);
});

test('CLI creates a project and dev watcher reloads edited source',async()=>{
 const {spawn}=await import('node:child_process');
 const cli=path.resolve('packages/cli/bin/platform.mjs'); const dir=path.join(root,'created-extension');
 const create=spawnSync(process.execPath,[cli,'create',dir],{encoding:'utf8'});good(create);
 const manifestPath=path.join(dir,'extension.json');const manifest=JSON.parse(fs.readFileSync(manifestPath));manifest.commands[0].keywords=['fresh'];fs.writeFileSync(manifestPath,JSON.stringify(manifest));
 const child=spawn(process.execPath,[cli,'dev',dir,'--accept-permissions'],{env:{...process.env,LAUNCHER_HOME:path.join(root,'dev')},stdio:['ignore','pipe','pipe']});
 let output='';child.stdout.on('data',x=>{output+=x});child.stderr.on('data',x=>{output+=x});
 const waitFor=async(fn)=>{const end=Date.now()+10000;while(!fn()&&Date.now()<end)await new Promise(r=>setTimeout(r,100));assert.ok(fn(),output)};
 try {
  await waitFor(()=>output.includes('Reloaded.'));
  const entry=path.join(dir,'src/index.ts');const source=fs.readFileSync(entry,'utf8');fs.writeFileSync(entry,source.replaceAll('query.toLocaleUpperCase()','"RELOADED"'));
  await waitFor(()=>(output.match(/Reloaded\./g)||[]).length>=2);
  const rows=JSON.parse(good(run('dev','--query',manifest.id,'transform','hello'))).items;assert.equal(rows[0].title,'RELOADED');
  const prefFile=path.join(root,'dev','preferences.json');const prefs=JSON.parse(good(run('dev','--preferences')));
  const statusDir=path.join(root,'dev','development');
  const state=()=>{try{return JSON.parse(fs.readFileSync(path.join(statusDir,fs.readdirSync(statusDir).find(x=>x.endsWith('.json')))))}catch{return {}}};
  prefs.developerAutoReload=false;fs.writeFileSync(prefFile,JSON.stringify(prefs));await new Promise(r=>setTimeout(r,700));
  fs.writeFileSync(entry,source.replaceAll('query.toLocaleUpperCase()','"RESUMED"'));await waitFor(()=>state().state==='paused');
  assert.equal(JSON.parse(good(run('dev','--query',manifest.id,'transform','hello'))).items[0].title,'RELOADED');
  prefs.developerAutoReload=true;fs.writeFileSync(prefFile,JSON.stringify(prefs));await waitFor(()=>state().state==='ready');
  assert.equal(JSON.parse(good(run('dev','--query',manifest.id,'transform','hello'))).items[0].title,'RESUMED');
  fs.writeFileSync(entry,'this is invalid TypeScript !!');await waitFor(()=>state().state==='error');assert.ok(state().message.length>0);
  fs.writeFileSync(entry,source);await waitFor(()=>state().state==='ready');
 } finally { child.kill('SIGINT');await new Promise(resolve=>child.once('exit',resolve)); }
});

test('superseded query cannot deliver after a newer query',()=>{
 const source='var Extension={default:{commands:[{id:"convert",query:async ctx=>{if(ctx.query==="slow"){const end=Date.now()+500;while(Date.now()<end){}}return {items:[{id:"result",title:ctx.query,actions:[]}]}}}]}};';
 good(install('race',fixture({source}),'--accept-permissions'));
 const result=JSON.parse(good(run('race','--verify-cancellation','test.sample')));
 assert.deepEqual(result,{oldDeliveries:0,newDeliveries:1});
 const direct=fixture({id:'test.direct',source});const pkg=JSON.parse(fs.readFileSync(direct));pkg.manifest.commands[0].inputMode='query';pkg.manifest.commands[0].keywords=[];pkg.manifest.commands[0].debounceMs=0;fs.writeFileSync(direct,JSON.stringify(pkg));
 good(install('implicit-race',direct,'--accept-permissions'));
 const implicit=JSON.parse(good(run('implicit-race','--verify-cancellation','test.direct','--implicit')));
 assert.deepEqual(implicit,{oldDeliveries:0,newDeliveries:1});
});

test('persisted aliases are honored when checking install keyword collisions',()=>{
 good(install('aliases',fixture({keywords:['original']}),'--accept-permissions'));
 const settings=JSON.parse(good(run('aliases','--preferences')));
 assert.equal(settings.hideOnBlur,true);settings.aliases={'test.sample/convert':'custom'};
 fs.writeFileSync(path.join(root,'aliases','preferences.json'),JSON.stringify(settings));
 bad(install('aliases',fixture({id:'test.other',keywords:['custom']}),'--accept-permissions'),/冲突/);
 good(install('aliases',fixture({id:'test.other',keywords:['original']}),'--accept-permissions'));
 assert.equal(JSON.parse(good(run('aliases','--preferences'))).aliases['test.sample/convert'],'custom');
});

test('application plugin reads catalog in XPC and returns a validated Finder open action',async()=>{
 const p=await pack('extensions/applications');good(install('apps',p.output,'--accept-permissions'));
 const rows=JSON.parse(good(run('apps','--implicit-query','Finder'))).items;
 const finder=rows.find(x=>x.applicationPath?.endsWith('/Finder.app'));
 assert.ok(finder);assert.equal(finder.extensionID,'local.applications');assert.ok(finder.applicationId);
 assert.deepEqual(finder.actions.map(x=>x.type),['application.open','application.reveal','application.info','application.contents','storage.toggle']);assert.equal(finder.actions[0].text,finder.applicationId);
});
test('application capabilities reject undeclared reads and forged open targets',()=>{
 const denied='var Extension={default:{commands:[{id:"convert",query:async ctx=>{await ctx.applications.list();return {items:[]}}}]}};';
 good(install('apps-denied',fixture({source:denied}),'--accept-permissions'));bad(run('apps-denied','--query','test.sample','convert','x'),/应用列表/);
 const forged='var Extension={default:{commands:[{id:"convert",query:async ctx=>{await ctx.applications.list();return {items:[{id:"fake",title:"Fake",applicationId:"unissued-id",applicationPath:"/Applications/Terminal.app",actions:[{id:"open",title:"Open",type:"application.open",text:"unissued-id"}]}]}}}]}};';
 good(install('apps-forged',fixture({source:forged,permissions:{applications:['read','open']}}),'--accept-permissions'));
 const rows=JSON.parse(good(run('apps-forged','--query','test.sample','convert','x'))).items;
 assert.deepEqual(rows[0].actions,[]);assert.equal(rows[0].applicationPath,undefined);assert.equal(rows[0].applicationId,undefined);
 const direct='var Extension={default:{commands:[{id:"convert",query:async()=>{await __rpc("application.open",{id:"any"});return {items:[]}}}]}};';
 good(install('apps-direct',fixture({source:direct,permissions:{applications:['read','open']}}),'--accept-permissions'));bad(run('apps-direct','--query','test.sample','convert','x'),/查询阶段/);
});

test('clipboard history uses permission-gated per-extension storage and strips forged deletion actions', async()=>{
 const home='clipboard-history';const built=await pack('extensions/clipboard-history');
 good(install(home,built.output,'--accept-permissions'));
 const dir=path.join(root,home,'ClipboardHistory');fs.mkdirSync(dir,{recursive:true});
 const seed=[{id:'known',text:'HISTORY_FIXTURE\nsecond line',source:'Test App',timestamp:Date.now()}];
 fs.writeFileSync(path.join(dir,'local.clipboard-history.json'),JSON.stringify(seed));
 const rows=JSON.parse(good(run(home,'--query','local.clipboard-history','history','fixture'))).items;
 assert.equal(rows[0].preview.text,seed[0].text);assert.equal(rows[0].actions[0].type,'clipboard.history.copy');assert.equal(rows[0].actions[0].text,'known');assert.equal(rows[0].actions[2].type,'clipboard.history.remove');assert.equal(rows[0].actions[2].text,'known');
 const source='var Extension={default:{commands:[{id:"convert",query:async ctx=>{const entries=await ctx.clipboard.history();return {items:[{id:"one",title:String(entries.length),actions:[{id:"delete",title:"Delete",type:"clipboard.history.remove",text:"known"},{id:"copy",title:"Copy",type:"clipboard.history.copy",text:"known"}],preview:{historyImageID:"known"}}]}}}]}};';
 good(install(home,fixture({source}),'--accept-permissions'));
 bad(run(home,'--query','test.sample','convert',''),/历史权限/);
 good(install(home,fixture({version:'1.1.0',source,permissions:{clipboard:['history']}}),'--accept-permissions'));
 const own=JSON.parse(good(run(home,'--query','test.sample','convert',''))).items;
 assert.equal(own[0].title,'0');assert.deepEqual(own[0].actions,[]);assert.equal(own[0].preview?.historyImageID,undefined);
 const mutate='var Extension={default:{commands:[{id:"convert",query:async()=>{await __rpc("clipboard.history.clear",{});return {items:[]}}}]}};';
 good(install(home,fixture({id:'test.mutate',keywords:['mutate'],source:mutate,permissions:{clipboard:['history']}}),'--accept-permissions'));
 bad(run(home,'--query','test.mutate','convert',''),/查询阶段/);
 assert.equal(JSON.parse(fs.readFileSync(path.join(dir,'local.clipboard-history.json'))).length,1);
});

test('application menu rejects forged file actions and malformed shortcuts',()=>{
 const source='var Extension={default:{commands:[{id:"convert",query:async ctx=>{const apps=await ctx.applications.list();const app=apps[0];return {items:[{id:"valid",title:app.name,applicationId:app.id,actions:[{id:"ok",title:"Reveal",type:"application.reveal",text:app.id,shortcut:{key:"i",modifiers:["command"]}},{id:"forged",title:"Bad",type:"application.contents",text:"forged"},{id:"plain",title:"Info",type:"application.info",text:app.id,shortcut:{key:"i",modifiers:[]}}]},{id:"fake",title:"Fake",applicationId:"forged",actions:[{id:"bad",title:"Bad",type:"application.info",text:"forged"}]}]}}}]}};';
 good(install('app-menu',fixture({source,permissions:{applications:['read','open']}}),'--accept-permissions'));
 const rows=JSON.parse(good(run('app-menu','--query','test.sample','convert','x'))).items;
 assert.deepEqual(rows[0].actions.map(x=>x.id),['ok','plain']);assert.equal(rows[0].actions[1].shortcut,undefined);assert.equal(rows[1].actions.length,0);
});

test('query can read only its own action state and cannot mutate it',()=>{
 const source='var Extension={default:{commands:[{id:"convert",query:async ctx=>({items:[{id:"state",title:JSON.stringify(await ctx.storage.flags()),actions:[]}]})}]}};';
 const home='action-state';good(install(home,fixture({source}),'--accept-permissions'));
 const dir=path.join(root,home,'ActionState');fs.mkdirSync(dir,{recursive:true});
 fs.writeFileSync(path.join(dir,'test.sample.json'),JSON.stringify({mine:true}));fs.writeFileSync(path.join(dir,'test.other.json'),JSON.stringify({other:true}));
 assert.deepEqual(JSON.parse(JSON.parse(good(run(home,'--query','test.sample','convert','x'))).items[0].title),{mine:true});
 const mutation='var Extension={default:{commands:[{id:"convert",query:async()=>{await __rpc("storage.toggle",{key:"mine"});return {items:[]}}}]}};';
 good(install(home,fixture({source:mutation,version:'1.0.1'}),'--accept-permissions'));bad(run(home,'--query','test.sample','convert','x'),/查询阶段/);
 assert.deepEqual(JSON.parse(fs.readFileSync(path.join(dir,'test.sample.json'))),{mine:true});
});

test('catalog capability requires read consent and never installs during queries',()=>{
 for(const [name,method,permissions,pattern] of [
  ['catalog-denied','catalog.list',{},/目录.*权限/],
  ['catalog-query-install','catalog.install',{catalog:['read','install']},/查询阶段/],
 ]) {
  const source=`var Extension={default:{commands:[{id:"convert",query:async()=>{await __rpc('${method}',{});return {items:[]}}}]}};`;
  good(install(name,fixture({source,permissions}),'--accept-permissions'));
  bad(run(name,'--query','test.sample','convert','x'),pattern);
 }
});
test('generic page actions survive while forged catalog handles and unsafe browser URLs are removed',()=>{
 const source='var Extension={default:{commands:[{id:"convert",query:async()=>({items:[{id:"one",title:"Details",catalogID:"forged",preview:{text:"Description"},actions:[{id:"details",title:"Details",type:"view.detail",text:""},{id:"install",title:"Install",type:"catalog.install",text:"forged"},{id:"bad",title:"Unsafe",type:"url.open",text:"file:///etc/passwd"},{id:"credentials",title:"Credentials",type:"url.open",text:"https://user:secret@example.com"},{id:"web",title:"Readme",type:"url.open",text:"https://github.com/test/plugins"}]}]})}]}};';
 good(install('catalog-sanitize',fixture({source,permissions:{catalog:['read','install'],browser:['open']}}),'--accept-permissions'));
 const row=JSON.parse(good(run('catalog-sanitize','--query','test.sample','convert','x'))).items[0];
 assert.equal(row.catalogID,undefined);assert.deepEqual(row.actions.map(a=>a.type),['view.detail','url.open']);
 good(install('browser-denied',fixture({source}),'--accept-permissions'));
 assert.deepEqual(JSON.parse(good(run('browser-denied','--query','test.sample','convert','x'))).items[0].actions.map(a=>a.type),['view.detail']);
});

test('catalog RPC rejects source overrides before network access',()=>{
 const source='var Extension={default:{commands:[{id:"convert",query:async()=>{await __rpc("catalog.list",{repository:"attacker/other"});return {items:[]}}}]}};';
 good(install('catalog-fixed-source',fixture({source,permissions:{catalog:['read']}}),'--accept-permissions'));
 bad(run('catalog-fixed-source','--query','test.sample','convert','x'),/固定使用 Vectracast.*Vectracast-Plugins/);
});
