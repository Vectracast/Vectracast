// End-to-end Sparkle QA uses an isolated app identity, temporary signing key,
// loopback server and throwaway app bundles. Never updates the installed Vectracast.
import fs from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
import {execFileSync,spawn} from 'node:child_process';
import {generateKeyPairSync} from 'node:crypto';
import assert from 'node:assert/strict';
const root=path.resolve('build/qa/updater');await fs.mkdir(root,{recursive:true});
const dir=await fs.mkdtemp(path.join(root,'run-'));
const framework=path.resolve('build/dependencies/sparkle-2.10.0');
const {privateKey,publicKey}=generateKeyPairSync('ed25519');
const seed=privateKey.export({format:'der',type:'pkcs8'}).subarray(-32).toString('base64');
const pub=publicKey.export({format:'der',type:'spki'}).subarray(-32).toString('base64');
let feed,archive,mode='valid';
const server=http.createServer((req,res)=>{
 if(req.url==='/appcast.xml'){res.setHeader('Content-Type','application/xml');res.end(mode==='feed-tamper'?feed.replace('2.0.0','9.0.0'):feed);}
 else if(req.url==='/Update.zip'){
  res.setHeader('Content-Length',archive.length);
  const bytes=Buffer.from(archive);if(mode==='archive-tamper')bytes[Math.floor(bytes.length/2)]^=1;
  // Delay chunks enough to observe and exercise the progress UI.
  let offset=0;const timer=setInterval(()=>{if(offset>=bytes.length){clearInterval(timer);res.end();}else{res.write(bytes.subarray(offset,offset+65536));offset+=65536;}},30);res.on('close',()=>clearInterval(timer));
 }else{res.statusCode=404;res.end();}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const base=`http://127.0.0.1:${server.address().port}/`;
const source=path.join(dir,'Harness.swift');
await fs.writeFile(source,`import AppKit
import Sparkle
class FlippedView: NSView { override var isFlipped: Bool { true } }
enum BrandAssets { static let logo = NSImage(size: NSSize(width:32,height:32)) }
final class Delegate: NSObject, NSApplicationDelegate {
 var ui: DistributionWindow!; var timer: Timer?; var clicked=false
 func applicationDidFinishLaunching(_ note: Notification) {
  let base=Bundle.main.bundleURL.deletingLastPathComponent()
  if Bundle.main.infoDictionary?["CFBundleVersion"] as? String == "2" {
   try! Data("restarted 2".utf8).write(to:base.appendingPathComponent("success")); NSApp.terminate(nil); return
  }
  NSApp.setActivationPolicy(.accessory)
  ui=DistributionWindow();ui.show()
  timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[self] _ in
   func all(_ v:NSView)->[NSView]{[v]+v.subviews.flatMap(all)}
   let views=all(ui.window.contentView!)
   let labels=views.compactMap{($0 as? NSTextField)?.stringValue}
   try? Data(labels.joined(separator:"\\n").utf8).write(to:base.appendingPathComponent("state"),options:.atomic)
   if labels.contains("更新未完成") {
    try? Data(labels.joined(separator:"\\n").utf8).write(to:base.appendingPathComponent("error"));NSApp.terminate(nil)
   }
   if !clicked, let b=views.compactMap({$0 as? NSButton}).first(where:{$0.title=="更新并重启" && !$0.isHidden}) {clicked=true;b.performClick(nil)}
  }
 }
}
@main struct Main {static func main(){let app=NSApplication.shared;let delegate=Delegate();app.delegate=delegate;app.run();withExtendedLifetime(delegate){}}}
`);
const executable=path.join(dir,'QA');
execFileSync('swiftc',['apps/macos/Sources/DistributionWindow.swift',source,'-F',framework,'-framework','Sparkle','-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks','-o',executable]);
async function bundle(destination,version,identity){
 await fs.mkdir(path.join(destination,'Contents/MacOS'),{recursive:true});await fs.mkdir(path.join(destination,'Contents/Frameworks'),{recursive:true});
 await fs.copyFile(executable,path.join(destination,'Contents/MacOS/QA'));
 execFileSync('ditto',[path.join(framework,'Sparkle.framework'),path.join(destination,'Contents/Frameworks/Sparkle.framework')]);
 await fs.writeFile(path.join(destination,'Contents/Info.plist'),`<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
 <key>CFBundleExecutable</key><string>QA</string><key>CFBundleIdentifier</key><string>${identity}</string><key>CFBundleName</key><string>Vectracast Update QA</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>${version}</string><key>CFBundleShortVersionString</key><string>${version}.0.0</string><key>LSMinimumSystemVersion</key><string>13.3</string><key>LSUIElement</key><true/>
 <key>SUFeedURL</key><string>${base}appcast.xml</string><key>SUPublicEDKey</key><string>${pub}</string><key>SUEnableAutomaticChecks</key><false/><key>SUAutomaticallyUpdate</key><false/><key>SUVerifyUpdateBeforeExtraction</key><true/><key>SURequireSignedFeed</key><true/><key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict></dict></plist>`);
 execFileSync('codesign',['--force','--sign','-',destination],{stdio:'pipe'});
}
try {
 for(const scenario of ['feed-tamper','archive-tamper','valid']) {
  mode=scenario;const runDir=path.join(dir,scenario);await fs.mkdir(runDir,{recursive:true});
  const identity='com.vectracast.update-qa.'+path.basename(dir).toLowerCase()+'.'+scenario;
  const current=path.join(runDir,'Vectracast Update QA.app');const next=path.join(dir,'next-'+scenario,'Vectracast Update QA.app');
  await bundle(current,1,identity);await bundle(next,2,identity);
  const staging=path.join(dir,'feed-'+scenario);await fs.mkdir(staging,{recursive:true});const zip=path.join(staging,'Update.zip');
  execFileSync('ditto',['-c','-k','--sequesterRsrc','--keepParent',next,zip]);
  await fs.writeFile(path.join(staging,'Update.md'),'# 更新验证\n\n- 独立测试应用更新与重新启动。');
  execFileSync(path.join(framework,'bin/generate_appcast'),['--ed-key-file','-','--download-url-prefix',base,'--embed-release-notes','--maximum-deltas','0',staging],{input:seed+'\n',stdio:['pipe','pipe','pipe']});
  feed=await fs.readFile(path.join(staging,'appcast.xml'),'utf8');archive=await fs.readFile(zip);
  const child=spawn(path.join(current,'Contents/MacOS/QA'),[],{stdio:'ignore'});
  try {
   let outcome;
   for(let n=0;n<180;n++) {
    if(await fs.stat(path.join(runDir,'success')).catch(()=>null)){outcome='success';break;}
    if(await fs.stat(path.join(runDir,'error')).catch(()=>null)){outcome='error';break;}
    await new Promise(r=>setTimeout(r,500));
   }
   assert.equal(outcome,scenario==='valid'?'success':'error',await fs.readFile(path.join(runDir,'state'),'utf8').catch(()=> 'no UI state'));
   const version=execFileSync('/usr/libexec/PlistBuddy',['-c','Print :CFBundleVersion',path.join(current,'Contents/Info.plist')],{encoding:'utf8'}).trim();
   assert.equal(version,scenario==='valid'?'2':'1');
   console.log('PASS:',scenario,scenario==='valid'?'app replaced and relaunched':'rejected, original app retained');
  } finally { if(child.exitCode===null) child.kill('SIGTERM'); }
 }
 console.log('QA evidence:',dir);
} finally { await new Promise(r=>server.close(r)); }
