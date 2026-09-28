import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import { pack, validateManifest } from '../../packages/cli/bin/platform.mjs';
const packed = await pack('extensions/calculator');
const pkg = JSON.parse(await fs.readFile(packed.output, 'utf8'));
const extension = vm.runInNewContext(pkg.source + '\nExtension.default', {});
async function rows(query) { return JSON.parse(JSON.stringify(await extension.commands[0].query({query}))).items; }
for (const [input, expected] of [
 ['12 * (100) +50','1250'], ['12 ×（100）＋50','1250'], ['１２＊（１００）＋５０','1250'],
 ['100 x 200 + 500','20500'], ['100x200+500','20500'], ['100 X 200 + 500','20500'],
 ['100 除 100 乘 100','100'], ['100除以100乘以100','100'], ['100除10乘2','20'],
 ['10加2乘3减4除以2','14'], ['（１００加２０）除以３','40'], ['2乘以(3加4)','14'],
 ['10减-2','12'], ['0xff加1转十六进制','0x100'], ['1除以3','0.33333333333333333333'],
 ['１００ｘ２００＋５００','20500'], ['2x(3+4)','14'], ['(2+3)x-4','-20'], ['1e2x.5','50'],
 ['2x3x4','24'], ['0xff x 2','510'], ['0xffx2','510'], ['0b10x0x10','32'], ['0x200','512'],
 ['(2+3)*4','20'], ['0.1+0.2','0.3'], ['-2^2','-4'], ['2^3^2','512'], ['2^-3','0.125'],
 ['-7 % 3','-1'], ['7 % -3','1'], ['1e3+2.5e-1','1000.25'],
 ['0xff03','65283'], ['0XFF + 0b1','256'], ['0o77 + 1','64'], ['0b1010 * 0x10','160'],
 ['255 to hex','0xFF'], ['0xff 转十进制','255'], ['hex(12*(100)+50)','0x4E2'], ['255转2进制','0b11111111'],
 ['0xffffffffffffffff','18446744073709551615'], ['9007199254740993+1','9007199254740994'],
 ['-255 to hex','-0xFF'], ['0xff+1 to bin','0b100000000'],
]) test(`calculator: ${input}`, async()=>{
 const result = await rows(input); assert.equal(result[0]?.title,expected); assert.equal(result[0].actions[0].text,expected);
});
test('conversion rows and long integer copies stay exact',async()=>{
 const result=await rows('0xff03'); assert.deepEqual(result.map(x=>x.title),['65283','0xFF03','0b1111111100000011','0o177403']);
 const huge=await rows('2^100');assert.equal(huge[0].title,'1267650600228229401496703205376');assert.equal(huge[1].title,'0x10000000000000000000000000');
});
test('unmatched searches yield no results; incomplete math produces non-actionable hints',async()=>{
 for (const s of ['', 'Safari','yd hello','1Password','process.exit()', 'hello 123','Xcode','加速器','删除文件','乘车','100除法教程']) assert.deepEqual(await rows(s),[]);
 for (const s of ['1/0','1%0','0x','0b102','0o89','100x','100xx200','1+','100乘以','100除','1除以0','(1+2','1 2','1.2.3','1e999','2^129','1.5 to hex']) {
  const result=await rows(s); assert.equal(result.length,1,s);assert.equal(result[0].id,'error',s);assert.deepEqual(result[0].actions,[],s);
 }
 assert.match((await rows('1/3'))[0].subtitle,/约值/);
});
test('manifest allows keywordless commands only with explicit query mode',()=>{
 validateManifest({...pkg.manifest,commands:[{id:'root',title:'root',keywords:[],inputMode:'query'}]});
 assert.throws(()=>validateManifest({...pkg.manifest,commands:[{id:'root',title:'root',keywords:[]}]}));
 assert.throws(()=>validateManifest({...pkg.manifest,commands:[{id:'root',title:'root',keywords:['ok'],inputMode:'typo'}]}));
});
