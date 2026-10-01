import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

test('registry client validates independent versions and rejects mismatched update targets', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vectracast-registry-'));
  try {
    fs.copyFileSync('extensions/calculator/extension.json', path.join(root, 'manifest.json'));
    fs.writeFileSync(path.join(root, 'Check.swift'), `
import Foundation
func rejects(_ body: () throws -> Void) { do { try body(); fatalError("Expected rejection") } catch {} }
@main struct Check {
 static func main() async throws {
  let root = URL(fileURLWithPath: CommandLine.arguments[1])
  let repo = try PublicRepository(DistributionSource.pluginRepository)
  let raw = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
  func entry(_ version: String, minimum: String = "0.7.0") throws -> PluginIndex.Entry {
    var json = try JSONSerialization.jsonObject(with: raw) as! [String: Any]; json["version"] = version
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: JSONSerialization.data(withJSONObject: json))
    return PluginIndex.Entry(manifest: manifest, asset: "local.calculator-\\(version).launcher-extension", sha256: String(repeating: "a", count: 64), minimumAppVersion: minimum, downloadURL: "/v2/plugins/local.calculator/versions/\\(version)/download")
  }
  let old = try entry("1.9.0"), latest = try entry("1.10.0")
  let info = InstalledExtension(manifest: old.manifest, source: root.path, enabled: true, previous: nil, preferences: [:], development: false)
  let development = InstalledExtension(manifest: old.manifest, source: root.path, enabled: true, previous: nil, preferences: [:], development: true)
  func service(_ entries: [PluginIndex.Entry]) throws -> PluginCatalogService {
    let payload = try JSONSerialization.data(withJSONObject: ["updates": entries.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }])
    return PluginCatalogService(cacheURL: root.appendingPathComponent("cache.json"), fetchUpdates: { data in
      let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      assert(request["appVersion"] as? String == "0.11.0")
      assert((request["plugins"] as! [[String: String]]) == [["id": "local.calculator", "version": "1.9.0"]])
      return payload
    })
  }
  let valid = try service([latest])
  let updates = try await valid.updates(for: [info], appVersion: "0.11.0")
  assert(updates.update(for: info)?.1.manifest.version == "1.10.0")
  assert(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cache.json").path))
  let noUpdate = try await service([]).updates(for: [info], appVersion: "0.11.0"); assert(noUpdate.entries.isEmpty)
  let dev = try await valid.updates(for: [development], appVersion: "0.11.0"); assert(dev.entries.isEmpty)
  for bad in [[old], [try entry("1.8.0")], [try entry("1.10.0", minimum: "9.0.0")], [latest, latest]] {
    do { _ = try await service(bad).updates(for: [info], appVersion: "0.11.0"); fatalError("Invalid update accepted") } catch {}
  }
  do { _ = try await valid.download("unknown"); fatalError("Unknown handle accepted") } catch {}
  let goodURL = try latest.registryDownloadURL(); assert(goodURL.path == latest.downloadURL)
  for path in [nil, "https://evil.example/pkg", "https://vectracast-api.fix030.com/v2/plugins/local.calculator/versions/1.10.0/download", "/v2/plugins/local.calculator/versions/1.9.0/download", "/v2/plugins/other/versions/1.10.0/download", latest.downloadURL! + "?token=bad", latest.downloadURL! + "#fragment"] as [String?] {
    var wrong = latest; wrong.downloadURL = path
    rejects { _ = try wrong.registryDownloadURL() }
    rejects { try CatalogCache(repository: repo.name, fetchedAt: Date(), index: PluginIndex(schemaVersion: 1, plugins: [wrong])).validate(for: repo) }
  }
  for path in ["/v2/plugins", "/v2/plugins/updates", "/v2/plugins/local.calculator/versions", "/v2/plugins/local.calculator/versions/1.10.0/download"] {
    _ = try DistributionSource.transportURL(URL(string: "https://vectracast-api.fix030.com" + path)!)
  }
  for path in ["/admin/api/state", "/v2/plugins/../admin", "/v2/plugins/local.calculator/versions/01.0.0/download", "/v2/plugins/local.calculator/versions/1.0.0/download?source=other", "/v2/plugins/local.calculator/versions/1.0.0/download#fragment"] {
    rejects { _ = try DistributionSource.transportURL(URL(string: "https://vectracast-api.fix030.com" + path)!) }
  }
  print("PASS registry request, per-plugin versions, compatibility, cache isolation and download identity")
 }
}
`);
    const binary = path.join(root, 'check');
    const build = spawnSync('swiftc', ['-swift-version', '5', '-parse-as-library', 'apps/macos/Sources/Models.swift', 'apps/macos/Sources/Distribution.swift', 'apps/macos/Sources/PluginCatalogService.swift', path.join(root, 'Check.swift'), '-o', binary], {encoding:'utf8', timeout:60000});
    assert.equal(build.status, 0, build.stderr);
    const run = spawnSync(binary, [root], {encoding:'utf8', timeout:10000});
    assert.equal(run.status, 0, run.stderr + run.stdout);
  } finally { fs.rmSync(root, {recursive:true, force:true}); }
});
