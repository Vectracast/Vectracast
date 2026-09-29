import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

test('update UI handles progress, cancellation, errors and only installs after user intent',()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'vectracast-update-ui-'));
 try {
 const source=path.join(dir,'Check.swift');
 fs.writeFileSync(source,`import AppKit
import Sparkle
class FlippedView: NSView { override var isFlipped: Bool { true } }
enum BrandAssets { static let logo = NSImage(size: NSSize(width: 32, height: 32)) }
@main struct Check {
 @MainActor static func main() {
  _ = NSApplication.shared
  let ui = DistributionWindow()
  func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
  let views = all(ui.window.contentView!)
  let progress = views.compactMap { $0 as? NSProgressIndicator }.first!
  func button(_ title: String) -> NSButton { views.compactMap { $0 as? NSButton }.first { $0.title == title }! }
  func check(_ condition: Bool) { if !condition { fatalError("UI invariant failed") } }
  var cancelled = 0
  ui.showDownloadInitiated { cancelled += 1 }
  ui.showDownloadDidReceiveExpectedContentLength(100)
  ui.showDownloadDidReceiveData(ofLength: 40)
  check(!progress.isIndeterminate && progress.doubleValue == 0.4)
  ui.showDownloadDidReceiveExpectedContentLength(20)
  check(progress.doubleValue == 1)
  button("取消").performClick(nil)
  check(cancelled == 1)
  ui.dismissUpdateInstallation()
  check(progress.isHidden && button("重新检查").isEnabled)
  var acknowledged = false
  ui.showUpdaterError(NSError(domain:"QA",code:1,userInfo:[NSLocalizedDescriptionKey:"Network failed"]), acknowledgement:{acknowledged=true})
  check(acknowledged && button("重新检查").isEnabled)
  var installed = false
  ui.showReady(toInstallAndRelaunch: {choice in installed = choice == .install})
  check(!installed)
  button("安装并重启").performClick(nil)
  check(installed)
  ui.showDownloadDidStartExtractingUpdate()
  ui.showExtractionReceivedProgress(.nan)
  check(progress.doubleValue == 0 && !button("重新检查").isEnabled)
  installed = false
  ui.showReady(toInstallAndRelaunch: {choice in installed = choice == .install})
  check(installed)
  ui.dismissUpdateInstallation()
  var closed = false
  ui.showUserInitiatedUpdateCheck {closed=true}
  ui.windowWillClose(Notification(name:NSWindow.willCloseNotification))
  check(closed)
  print("PASS: progress, cancel, retry, extraction, restart intent and close")
 }
}`);
 const framework=path.resolve('build/dependencies/sparkle-2.10.0');
 const binary=path.join(dir,'check');
 const build=spawnSync('swiftc',['apps/macos/Sources/DistributionWindow.swift',source,'-F',framework,'-framework','Sparkle','-Xlinker','-rpath','-Xlinker',framework,'-o',binary],{encoding:'utf8'});
 assert.equal(build.status,0,build.stderr);
 const run=spawnSync(binary,[],{encoding:'utf8',timeout:20000});assert.equal(run.status,0,run.stdout+run.stderr);
 assert.match(run.stdout,/PASS:/);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});
