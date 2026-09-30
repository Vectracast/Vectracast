import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import { pack, validateManifest } from '../../packages/cli/bin/platform.mjs';
const p=await pack('extensions/applications');const pkg=JSON.parse(await fs.readFile(p.output,'utf8'));
const extension=vm.runInNewContext(pkg.source+'\nExtension.default',{});
const apps=[{id:'b',name:'Super Notes',bundleIdentifier:'test.b',searchTerms:[]},{id:'c',name:'Notes Pro',bundleIdentifier:'test.c',searchTerms:[]},{id:'a',name:'Notes',bundleIdentifier:'test.a',searchTerms:[]},{id:'d',name:'备忘录',bundleIdentifier:'test.d',searchTerms:['beiwanglu']}];
let calls=0;
async function query(input, sensitivity='medium'){return JSON.parse(JSON.stringify(await extension.commands[0].query({query:input,search:{sensitivity},storage:{flags:async()=>({})},applications:{list:async()=>{calls++;return apps}}}))).items;}
test('sensitivity expands matching without changing direct match priority',async()=>{
 assert.deepEqual((await query('sn','high')).map(x=>x.title),[]);
 assert.equal((await query('sn','medium'))[0].title,'Super Notes');
 assert.deepEqual(await query('nt','medium'),[]);
 assert.deepEqual((await query('nt','low')).map(x=>x.title),['Notes','Notes Pro']);
 assert.equal((await query('notes','low'))[0].title,'Notes');
 assert.deepEqual(await query('nsz','low'),[]);
});
test('application matching/ranking and action creation are provided by the plugin',async()=>{
 const rows=await query('notes');assert.deepEqual(rows.map(x=>x.title),['Notes','Notes Pro','Super Notes']);
 assert.deepEqual(rows[0].actions.map(x=>x.type),['application.open','application.reveal','application.info','application.contents','storage.toggle']);assert.equal(rows[0].actions[0].text,'a');assert.equal(rows[0].applicationId,'a');
 assert.equal((await query('beiwang'))[0].title,'备忘录');
});

test('application search matches bundle identifier components such as Apple without matching generic com',async()=>{
 const fixtures=[
  {id:'safari',name:'Safari',bundleIdentifier:'com.apple.Safari',searchTerms:[]},
  {id:'music',name:'Music',bundleIdentifier:'com.apple.Music',searchTerms:[]},
  {id:'calendar',name:'Calendar',bundleIdentifier:'com.apple.iCal',searchTerms:[]},
  {id:'chrome',name:'Google Chrome',bundleIdentifier:'com.google.Chrome',searchTerms:[]},
 ];
 const search=async (query,sensitivity='medium')=>(await extension.commands[0].query({query,search:{sensitivity},storage:{flags:async()=>({})},applications:{list:async()=>fixtures}})).items;
 assert.deepEqual((await search('Apple')).map(row=>row.id),['calendar','music','safari']);
 assert.deepEqual((await search('com.apple')).map(row=>row.id),['calendar','music','safari']);
 assert.deepEqual((await search('apple','high')).map(row=>row.id),['calendar','music','safari']);
 assert.deepEqual(await search('com','high'),[]);
 assert.equal((await search('apple.music'))[0].id,'music');
});
test('unmatched and empty application searches do not create results',async()=>{
 assert.deepEqual(await query('0xff03'),[]);calls=0;assert.deepEqual(await query(' '),[]);assert.equal(calls,0);
});
test('a single letter or Chinese character matches names and pinyin immediately',async()=>{
 for (const sensitivity of ['high','medium','low']) {
  assert.deepEqual((await query('n',sensitivity)).map(row=>row.title),['Notes','Notes Pro','Super Notes','备忘录']);
  assert.equal((await query('b',sensitivity))[0].title,'备忘录');
  assert.equal((await query('备',sensitivity))[0].title,'备忘录');
 }
});
test('application open permission requires list permission',()=>{
 assert.throws(()=>validateManifest({...pkg.manifest,permissions:{applications:['open']}}));
 assert.throws(()=>validateManifest({...pkg.manifest,permissions:{applications:['shell']}}));
 validateManifest(pkg.manifest);
});

test('pinyin full spelling, syllable separators, initials and tones find Chinese names',async()=>{
 const fixtures = [
  {id:'wx',name:'微信',bundleIdentifier:'test.wechat',searchTerms:['WeChat','weixin','wei xin','wx']},
  {id:'tools',name:'微信开发者工具',bundleIdentifier:'test.tools',searchTerms:['wechatwebdevtools','weixinkaifazhegongju','wei xin kai fa zhe gong ju','wxkfzgj']},
  {id:'notes',name:'备忘录',bundleIdentifier:'test.notes',searchTerms:['Notes','beiwanglu','bei wang lu','bwl']},
 ];
 const search = async query => (await extension.commands[0].query({query,search:{sensitivity:'high'},storage:{flags:async()=>({})},applications:{list:async()=>fixtures}})).items;
 for (const input of ['weixin','WEIXIN','wei xin','wei x','wēi xìn',"wei'xin",'wx','WX','微信','WeChat']) {
  assert.equal((await search(input))[0].title,'微信',input);
 }
 assert.equal((await search('wxkf'))[0].title,'微信开发者工具');
 assert.equal((await search('wxkfzgj'))[0].title,'微信开发者工具');
 assert.equal((await search('bwl'))[0].title,'备忘录');
 assert.equal((await search('bei wang lu'))[0].title,'备忘录');
 assert.equal((await search('not-installed')).length,0);
 assert.equal((await search("''")).length,0);
 assert.equal((await search('wx'))[0].actions[0].text,'wx');
});

test('browser category aliases require installed HTTP, HTTPS and HTML support',async()=>{
 const fixtures=[
  {id:'safari',name:'Safari浏览器',bundleIdentifier:'com.apple.Safari',searchTerms:['Safari'],urlSchemes:['http','https'],documentTypes:['html']},
  {id:'edge',name:'Microsoft Edge',bundleIdentifier:'com.microsoft.edgemac',searchTerms:['Edge'],urlSchemes:['HTTP','HTTPS'],documentTypes:['public.html']},
  {id:'notes',name:'备忘录',bundleIdentifier:'com.apple.Notes',searchTerms:['Notes']},
  {id:'custom',name:'Custom App',bundleIdentifier:'test.custom',searchTerms:[],urlSchemes:['myapp','http','https']},
 ];
 const search=async query=>JSON.parse(JSON.stringify((await extension.commands[0].query({query,storage:{flags:async()=>({})},applications:{list:async()=>fixtures}})).items));
 for(const input of ['浏览器','browser','web browser','liulanqi','liu lan qi','llq']) {
  assert.deepEqual(new Set((await search(input)).map(x=>x.id)),new Set(['safari','edge']),input);
 }
 const safari=await search('Safari');assert.equal(safari.length,1);assert.equal(safari[0].actions[0].text,'safari');
 assert.equal((await search('Edge'))[0].id,'edge');
});

test('favorites persist in plugin state and break ranking ties without hiding exact matches',async()=>{
 const fixtures=[
  {id:'a',name:'Alpha Browser',bundleIdentifier:'test.alpha',searchTerms:[]},
  {id:'z',name:'Zulu Browser',bundleIdentifier:'test.zulu',searchTerms:[]},
  {id:'exact',name:'Browser',bundleIdentifier:'test.exact',searchTerms:[]},
 ];
 const rows=(await extension.commands[0].query({query:'browser',storage:{flags:async()=>({'favorite:test.zulu':true})},applications:{list:async()=>fixtures}})).items;
 assert.deepEqual(Array.from(rows,x=>x.id),['exact','z','a']);
 const favorite=rows[1].actions.find(x=>x.id==='favorite');
 assert.equal(favorite.title,'取消收藏');assert.equal(favorite.text,'favorite:test.zulu');
 assert.equal(rows[2].actions.find(x=>x.id==='favorite').title,'添加到收藏');
 for(const item of rows) for(const action of item.actions.filter(x=>x.type.startsWith('application.'))) assert.equal(action.text,item.applicationId);
});
