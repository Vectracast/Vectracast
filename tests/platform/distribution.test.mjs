import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import {
  buildPluginRelease,
  validateUpgrade,
  compareVersions,
} from "../../scripts/build-plugin-release.mjs";

test("catalog releases reject rewritten versions and downgrades", () => {
  const old = {
    manifest: { id: "test.plugin", version: "1.2.0" },
    sha256: "a",
  };
  assert.equal(compareVersions("1.10.0", "1.9.9"), 1);
  assert.equal(compareVersions("2.0.0", "10.0.0"), -1);
  assert.throws(() => compareVersions("v1.0.0", "1.0.0"));
  validateUpgrade(old, old);
  validateUpgrade(
    { ...old, manifest: { ...old.manifest, version: "1.2.1" }, sha256: "b" },
    old,
  );
  assert.throws(
    () => validateUpgrade({ ...old, sha256: "b" }, old),
    /version bump/,
  );
  assert.throws(
    () =>
      validateUpgrade(
        { ...old, manifest: { ...old.manifest, version: "1.1.0" } },
        old,
      ),
    /downgrade/,
  );
});

test("published catalog and packages agree and native reader rejects tampering", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vectracast-catalog-"));
  try {
    const index = await buildPluginRelease("extensions", dir);
    assert.ok(index.plugins.length >= 5);
    const relocated = path.join(dir, "relocated");
    fs.mkdirSync(relocated);
    for (const item of fs.readdirSync("extensions", { withFileTypes: true })) {
      if (
        item.isDirectory() &&
        fs.existsSync(path.join("extensions", item.name, "extension.json"))
      ) {
        fs.cpSync(
          path.join("extensions", item.name),
          path.join(relocated, item.name),
          { recursive: true, filter: (p) => path.basename(p) !== "dist" },
        );
      }
    }
    const rebuilt = await buildPluginRelease(
      relocated,
      path.join(dir, "rebuilt"),
      path.join(dir, "index.json"),
    );
    assert.deepEqual(
      rebuilt,
      index,
      "Release packages must not depend on checkout paths",
    );
    fs.writeFileSync(
      path.join(dir, "main.swift"),
      `
import Foundation
func rejects(_ body: () throws -> Void) { do { try body(); fatalError("Expected rejection") } catch {} }
let ordered = try ReleaseVersion("v1.10.0") > ReleaseVersion("1.9.9"); assert(ordered)
let equal = try ReleaseVersion("0.7.0") == ReleaseVersion("v0.7.0"); assert(equal)
rejects { _ = try ReleaseVersion("1.0.0-beta.1") }
rejects { _ = try ReleaseVersion("01.2.3") }
UserDefaults.standard.set("attacker/other", forKey: "distribution.pluginRepository")
assert(DistributionSource.repository("pluginRepository") == "Vectracast/Vectracast-Plugins")
UserDefaults.standard.removeObject(forKey: "distribution.pluginRepository")
UserDefaults.standard.set("attacker/other", forKey: "distribution.appRepository")
assert(DistributionSource.repository("appRepository") == "Vectracast/Vectracast")
UserDefaults.standard.removeObject(forKey: "distribution.appRepository")
try DistributionSource.validateCatalogRequest([:])
rejects { try DistributionSource.validateCatalogRequest(["repository":"attacker/other"]) }
let api = "https://vectracast-api.fix030.com"
for (kind, name) in [("app", "Vectracast/Vectracast"), ("plugins", "Vectracast/Vectracast-Plugins")] {
 let latest = try DistributionSource.transportURL(PublicRepository(name).latestURL)
 assert(latest.absoluteString == api + "/v1/releases/" + kind + "/latest")
 let asset = try DistributionSource.transportURL(URL(string: "https://github.com/" + name + "/releases/download/v1.0.0/index.json")!)
 assert(asset.absoluteString == api + "/v1/assets/" + kind + "/v1.0.0/index.json")
 let unchanged = try DistributionSource.transportURL(asset); assert(unchanged == asset)
}
for address in [
 "https://api.github.com/repos/attacker/repo/releases/latest",
 "https://github.com/Vectracast/Vectracast-Plugins/releases/download/v1.0.0/index.json?source=other",
 "https://github.com/Vectracast/Vectracast-Plugins/releases/download/v1.0.0/nested/index.json",
 "http://vectracast-api.fix030.com/v1/releases/plugins/latest",
 "https://vectracast-api.fix030.com.evil.example/v1/releases/plugins/latest",
 "https://user:pass@vectracast-api.fix030.com/v1/releases/plugins/latest",
 "https://vectracast-api.fix030.com:8080/v1/releases/plugins/latest"
] { rejects { _ = try DistributionSource.transportURL(URL(string: address)!) } }
let repo = try PublicRepository("https://github.com/test/Vectracast-Plugins.git")
assert(repo.name == "test/Vectracast-Plugins")
rejects { _ = try PublicRepository("https://evil.example/test/repo") }
rejects { _ = try PublicRepository("test/repo/../../private") }
rejects { _ = try repo.assetURL("http://github.com/test/Vectracast-Plugins/releases/download/v1/index.json") }
rejects { _ = try repo.assetURL("https://github.com/other/repo/releases/download/v1/index.json") }
rejects { _ = try repo.assetURL("https://github.com/test/Vectracast-Plugins/releases/download/v1/index.json?token=bad") }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let raw = try Data(contentsOf: root.appendingPathComponent("index.json"))
let index = try JSONDecoder().decode(PluginIndex.self, from: raw); try index.validate()
for entry in index.plugins {
 let data = try Data(contentsOf: root.appendingPathComponent(entry.asset))
 let pkg = try entry.verify(data); assert(pkg.manifest.id == entry.manifest.id)
 rejects { _ = try entry.verify(data + Data(" ".utf8)) }
}
var json = try JSONSerialization.jsonObject(with: raw) as! [String:Any]
json["plugins"] = [json["plugins"] as! [[String:Any]]].flatMap { $0 + $0 }
rejects { let bad = try JSONDecoder().decode(PluginIndex.self, from: JSONSerialization.data(withJSONObject: json)); try bad.validate() }
let asset = PublicRelease.Asset(name:"index.json",browser_download_url:"https://github.com/test/Vectracast-Plugins/releases/download/plugins-v1/index.json",size:42)
let release = PublicRelease(tag_name:"plugins-v1",body:"notes",draft:false,prerelease:false,assets:[asset])
let validAsset = try release.asset("index.json",repository:repo,limit:100); assert(validAsset.host == "github.com")
rejects { _ = try release.asset("missing.zip",repository:repo,limit:100) }
rejects { _ = try release.asset("index.json",repository:repo,limit:1) }
print("PASS: catalog, versions, URLs, immutable package identities and checksums")
`,
    );
    const binary = path.join(dir, "distribution");
    const build = spawnSync(
      "swiftc",
      [
        "-swift-version",
        "5",
        "apps/macos/Sources/Models.swift",
        "apps/macos/Sources/Distribution.swift",
        path.join(dir, "main.swift"),
        "-o",
        binary,
      ],
      { encoding: "utf8", timeout: 60000 },
    );
    assert.equal(build.status, 0, build.stderr);
    const run = spawnSync(binary, [dir], { encoding: "utf8", timeout: 10000 });
    assert.equal(run.status, 0, run.stderr + run.stdout);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("distribution build rejects plugin repository overrides", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vectracast-source-"));
  try {
    const out = path.join(dir, "distribution.json");
    const run = (source) => spawnSync(process.execPath, ["scripts/prepare-distribution.mjs", out], {
      encoding: "utf8", env: {...process.env, CI: "", VECTRACAST_PLUGIN_REPOSITORY: source},
    });
    const valid = run(""); assert.equal(valid.status, 0, valid.stderr);
    assert.equal(JSON.parse(fs.readFileSync(out)).pluginRepository, "Vectracast/Vectracast-Plugins");
    const invalid = run("attacker/other"); assert.notEqual(invalid.status, 0);
    assert.match(invalid.stderr, /repository is fixed/);
  } finally { fs.rmSync(dir, {recursive:true,force:true}); }
});
