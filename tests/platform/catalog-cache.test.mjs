import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

test('catalog cache survives restart, refreshes stale data, coalesces loads and rejects corrupt or foreign data', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vectracast-cache-'));
  try {
    fs.copyFileSync("extensions/calculator/extension.json", path.join(dir,"manifest.json"));
    const source = path.join(dir, 'CacheTest.swift');
    fs.writeFileSync(source, `
import Foundation
actor Fetcher {
 var calls = 0
 func fetch(_ repo: PublicRepository) async throws -> CatalogCache {
  calls += 1
  try await Task.sleep(nanoseconds: 150_000_000)
  return fixture(repo, "plugins-v2")
 }
}
func fixture(_ repo: PublicRepository, _ tag: String, age: Double = 0) -> CatalogCache {
 let root = URL(fileURLWithPath: CommandLine.arguments[1])
 var json = try! JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
 json["description"] = tag
 json["version"] = tag == "plugins-v2" ? "2.0.0" : "1.0.0"
 let manifest = try! JSONDecoder().decode(ExtensionManifest.self, from: JSONSerialization.data(withJSONObject: json))
 let entry = PluginIndex.Entry(manifest: manifest, asset: "\\(manifest.id)-\\(manifest.version).launcher-extension", sha256: String(repeating: "a", count: 64), minimumAppVersion: "0.7.0", downloadURL: "/v2/plugins/\\(manifest.id)/versions/\\(manifest.version)/download")
 return CatalogCache(repository: repo.name, fetchedAt: Date().addingTimeInterval(-age), index: PluginIndex(schemaVersion: 1, plugins: [entry]))
}
@main struct Test {
 static func main() async throws {
  let file = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("cache.json")
  let repo = try PublicRepository(DistributionSource.pluginRepository)
  let counter = Fetcher()
  let service = PluginCatalogService(cacheURL: file, fetch: { try await counter.fetch($0) })
  async let a = service.load(); async let b = service.load()
  _ = try await (a,b)
  let count = await counter.calls; assert(count == 1)
  assert(CatalogCache.read(file, repository: repo) != nil)
  let restarted = PluginCatalogService(cacheURL: file, fetch: { _ in fatalError("Fresh cache must not use network") })
  let fresh = try await restarted.load(); assert(fresh.entries[0].1.manifest.description == "plugins-v2")
  try fixture(repo, "plugins-v1", age: 3600).write(file)
  let stale = PluginCatalogService(cacheURL: file, fetch: { try await counter.fetch($0) })
  let first = try await stale.load(); assert(first.entries[0].1.manifest.description == "plugins-v1")
  try await Task.sleep(nanoseconds: 350_000_000)
  let updated = try await stale.load(); assert(updated.entries[0].1.manifest.description == "plugins-v2")
  // Re-reading identical metadata keeps handles stable; content changes do not rely on a batch tag.
  let stable = try await stale.load(); assert(stable.entries[0].0 == updated.entries[0].0)
  assert(first.entries[0].0 != updated.entries[0].0)
  assert(first.entries[0].1.manifest.version == "1.0.0" && updated.entries[0].1.manifest.version == "2.0.0")
  await stale.invalidate(); _ = try await stale.load()
  let refreshed = await counter.calls; assert(refreshed == 3)
  try fixture(repo, "plugins-v1", age: 3600).write(file)
  let offline = PluginCatalogService(cacheURL: file, fetch: { _ in throw LauncherError("Offline") })
  let fallback = try await offline.load(); assert(fallback.entries[0].1.manifest.description == "plugins-v1")
  try await Task.sleep(nanoseconds: 50_000_000)
  let fallbackAgain = try await offline.load(); assert(fallbackAgain.entries[0].1.manifest.description == "plugins-v1")
  try JSONEncoder().encode(fixture(repo, "old", age: 8 * 86400)).write(to: file)
  assert(CatalogCache.read(file, repository: repo) == nil)
  try JSONEncoder().encode(fixture(PublicRepository("other/plugins"), "foreign")).write(to: file)
  assert(CatalogCache.read(file, repository: repo) == nil)
  try Data("broken".utf8).write(to: file)
  assert(CatalogCache.read(file, repository: repo) == nil)
  print("PASS: cold coalescing, warm restart, background refresh, explicit refresh, offline cache, expiry and validation")
 }
}
`);
    const binary = path.join(dir, 'cache-test');
    const build = spawnSync('swiftc', ['-swift-version','5','-parse-as-library','apps/macos/Sources/Models.swift','apps/macos/Sources/Distribution.swift','apps/macos/Sources/PluginCatalogService.swift', source,'-o',binary], {encoding:'utf8',timeout:60000});
    assert.equal(build.status,0,build.stderr);
    const run = spawnSync(binary,[dir],{encoding:'utf8',timeout:10000});
    assert.equal(run.status,0,run.stderr + run.stdout);
  } finally { fs.rmSync(dir,{recursive:true,force:true}); }
});
