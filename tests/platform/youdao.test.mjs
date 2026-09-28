import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import path from 'node:path';
const result=await build({entryPoints:['extensions/youdao/src/index.ts'],bundle:true,write:false,format:'esm',platform:'node',alias:{'@platform/sdk':path.resolve('packages/sdk/src/index.ts')}});
const api=await import('data:text/javascript;base64,'+Buffer.from(result.outputFiles[0].text).toString('base64'));
test('v3 truncation counts Unicode code points',()=>{
 assert.equal(api.truncateInput('😀'.repeat(20)),'😀'.repeat(20));
 assert.equal(api.truncateInput('😀'.repeat(21)),'😀'.repeat(10)+'21'+'😀'.repeat(10));
});
test('response parser uses only supplied translations and distinct optional meanings',()=>{
 const items=api.parseYoudao({errorCode:'0',translation:['你好'],basic:{explains:['你好','问候']},web:[null,{key:'hi',value:['嗨']}]});
 assert.deepEqual(items.map(i=>i.title),['你好','问候','嗨']);assert.equal(items[0].actions[0].text,'你好');
 assert.throws(()=>api.parseYoudao({errorCode:'202'}),/签名/);
 assert.throws(()=>api.parseYoudao({errorCode:'401'}),/欠费/);
 assert.throws(()=>api.parseYoudao({errorCode:'412'}),/频繁/);
 assert.throws(()=>api.parseYoudao({errorCode:'0'}),/没有返回/);
});
test('translation constructs real official v3 request with correctly signed form',async()=>{
 let request;const hash=s=>createHash('sha256').update(s).digest('hex');
 const ctx={query:'Hello & world',rawInput:'yd Hello & world',preferences:{appKey:'test-app',target:'auto'},secrets:{get:async()=> 'fixture-secret'},crypto:{uuid:()=> 'fixed-salt',sha256:hash},network:{fetch:async(url,options)=>{request={url,...options};return {status:200,body:JSON.stringify({errorCode:'0',translation:['测试译文']})}}}};
 const result=await api.default.commands[0].query(ctx); const form=new URLSearchParams(request.body);
 assert.equal(request.url,'https://openapi.youdao.com/api');assert.equal(request.method,'POST');assert.equal(form.get('q'),ctx.query);assert.equal(form.get('to'),'zh-CHS');assert.equal(form.get('signType'),'v3');
 assert.equal(form.get('sign'),hash('test-app'+ctx.query+'fixed-salt'+form.get('curtime')+'fixture-secret'));assert.equal(result.items[0].title,'测试译文');assert.equal(form.has('appSecret'),false);
});
test('missing credentials and excessive input fail before network access',async()=>{
 const ctx={query:'hello',preferences:{},secrets:{get:async()=>''},network:{fetch:()=>{throw Error('should not call')}}};
 await assert.rejects(api.default.commands[0].query(ctx),/应用 ID/);
 await assert.rejects(api.default.commands[0].query({...ctx,query:'字'.repeat(5001)}),/5000/);
});
