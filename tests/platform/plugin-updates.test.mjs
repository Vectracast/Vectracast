import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {pack} from '../../packages/cli/bin/platform.mjs';

test('settings detects numeric plugin updates, protects development versions and offers direct update controls', async () => {
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'vectracast-plugin-updates-'));
 try {
  const built=await pack('extensions/calculator');
  const pkg=JSON.parse(fs.readFileSync(built.output));
  pkg.manifest.version='1.9.0';
  fs.writeFileSync(path.join(dir,'installed.json'),JSON.stringify(pkg));
  pkg.manifest.version='1.10.0';
  fs.writeFileSync(path.join(dir,'remote.json'),JSON.stringify(pkg));
  const source=path.join(dir,'Check.swift');
  fs.writeFileSync(source,`import AppKit
import CryptoKit
actor PackageDownload {
 var attempts = 0
 func fetch(_ data: Data) throws -> Data {
  attempts += 1
  if attempts == 1 { throw LauncherError("QA network failure") }
  if attempts == 2 { return Data("corrupt package".utf8) }
  return data
 }
}
enum BrandAssets { static let logo = NSImage(size: NSSize(width: 32, height: 32)); static let menuBar = NSImage(size: NSSize(width: 18, height: 18)) }
@main struct Check {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let root = URL(fileURLWithPath: CommandLine.arguments[1])
  let store = try ExtensionStore(root: root.appendingPathComponent("store"))
  _ = try store.install(Data(contentsOf: root.appendingPathComponent("installed.json")), acceptPermissions: true)
  let remote = try JSONDecoder().decode(ExtensionPackage.self, from: Data(contentsOf: root.appendingPathComponent("remote.json")))
  let remoteData = try Data(contentsOf: root.appendingPathComponent("remote.json"))
  let repo = try PublicRepository(DistributionSource.pluginRepository)
  let entry = PluginIndex.Entry(manifest: remote.manifest, asset: "local.calculator-1.10.0.launcher-extension", sha256: SHA256.hash(data: remoteData).map { String(format: "%02x", $0) }.joined(), minimumAppVersion: "0.7.0")
  let release = PublicRelease(tag_name: "test", body: nil, draft: false, prerelease: false, assets: ["index.json",entry.asset].map { PublicRelease.Asset(name: $0, browser_download_url: "https://github.com/\\(repo.name)/releases/download/test/\\($0)", size: 100) })
  let snapshot = PluginCatalogService.Snapshot(repository: repo, release: release, entries: [("handle", entry)], loaded: Date())
  let installed = store.list()[0]
  assert(snapshot.update(for: installed)?.1.manifest.version == "1.10.0")
  let development = InstalledExtension(manifest: installed.manifest, source: installed.source, enabled: true, previous: nil, preferences: [:], development: true)
  assert(snapshot.update(for: development) == nil)
  let downloader = PackageDownload()
  let service = PluginCatalogService(cacheURL: root.appendingPathComponent("cache.json"), fetchPackage: { _, _ in try await downloader.fetch(remoteData) }, fetch: { repository in
    CatalogCache(repository: repository.name, fetchedAt: Date(), release: release, index: PluginIndex(schemaVersion: 1, plugins: [entry]))
  })
  let ui = ExtensionWindow(store: store, catalogService: service)
  ui.window.setFrameAutosaveName("")
  func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
  let tab = all(ui.window.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "extensions" }!
  tab.performClick(nil)
  for _ in 0..<100 {
    if all(ui.window.contentView!).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue == "有 1 个插件可更新" }) { break }
    try await Task.sleep(nanoseconds: 20_000_000)
  }
  let views = all(ui.window.contentView!)
  assert(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "有 1 个插件可更新" })
  assert(views.compactMap { $0 as? NSButton }.contains { $0.title == "更新插件" && $0.isEnabled })
  let cell = ui.tableView(ui.table, viewFor: ui.table.tableColumns[1], row: 0)!
  assert(all(cell).compactMap { $0 as? NSButton }.contains { $0.title == "更新" && $0.isEnabled })
  assert(ui.window.sheets.isEmpty)
  try store.setEnabled(installed.manifest.id, false)
  try store.savePreferences(installed.manifest.id, ["qa": "retained"])
  func installFromRow() {
    let row = ui.tableView(ui.table, viewFor: ui.table.tableColumns[1], row: 0)!
    all(row).compactMap { $0 as? NSButton }.first { $0.title == "更新" }!.performClick(nil)
  }
  for message in ["QA network failure", "SHA-256"] {
    installFromRow()
    for _ in 0..<100 {
      if all(ui.form).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.contains(message) }) { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    assert(all(ui.form).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(message) })
    assert(store.list()[0].manifest.version == "1.9.0")
    assert(ui.window.sheets.isEmpty)
  }
  installFromRow()
  for _ in 0..<100 {
    if store.list()[0].manifest.version == "1.10.0" { break }
    try await Task.sleep(nanoseconds: 20_000_000)
  }
  assert(store.list()[0].manifest.version == "1.10.0")
  assert(!store.list()[0].enabled && store.list()[0].preferences["qa"] == "retained")
  assert(store.list()[0].previous == "1.9.0")
  assert(ui.window.sheets.isEmpty)
  ui.refreshInstalledExtensions()
  assert(snapshot.update(for: store.list()[0]) == nil)
  assert(!all(ui.form).compactMap { $0 as? NSButton }.contains { $0.title == "更新插件" })
  // An installed version newer than the catalog must never offer a downgrade.
  let oldEntry = PluginIndex.Entry(manifest: installed.manifest, asset: entry.asset, sha256: entry.sha256, minimumAppVersion: "0.7.0")
  let oldSnapshot = PluginCatalogService.Snapshot(repository: repo, release: release, entries: [("old",oldEntry)], loaded: Date())
  assert(oldSnapshot.update(for: store.list()[0]) == nil)
  print("PASS: numeric updates, development protection, direct controls, installed state and downgrade protection")
 }
}`);
  const framework=path.resolve('build/dependencies/sparkle-2.10.0');
  const sources=fs.readdirSync('apps/macos/Sources').filter(f=>f.endsWith('.swift') && f!=='main.swift' && f!=='BrandAssets.swift').map(f=>'apps/macos/Sources/'+f);
  const binary=path.join(dir,'check');
  const build=spawnSync('swiftc',['-swift-version','5','apps/macos/Shared/RuntimeProtocol.swift',...sources,source,'-F',framework,'-framework','Sparkle','-Xlinker','-rpath','-Xlinker',framework,'-o',binary],{encoding:'utf8',timeout:120000});
  assert.equal(build.status,0,build.stderr);
  const run=spawnSync(binary,[dir],{encoding:'utf8',timeout:20000,env:{...process.env,LAUNCHER_HOME:path.join(dir,'home')}});
  assert.equal(run.status,0,run.stdout+run.stderr);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});
