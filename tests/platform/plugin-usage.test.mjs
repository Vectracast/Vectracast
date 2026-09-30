import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

test('empty-search plugin list persists usage, ranks recent frequency and includes every enabled command', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vectracast-plugin-usage-'));
  try {
    fs.writeFileSync(path.join(root, 'main.swift'), `
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
func plugin(_ id: String, _ enabled: Bool = true) throws -> InstalledExtension {
    let json = """
    {"manifestVersion":1,"id":"local.\\(id)","name":"\\(id)","version":"1.0.0","description":"","runtime":"standard-js","sdk":"0.1","icon":"app","entry":"src/index.ts","commands":[{"id":"one","title":"One","keywords":["one"],"icon":"star"},{"id":"two","title":"Two","keywords":["two"]}],"permissions":{},"preferences":[]}
    """
    return InstalledExtension(manifest: try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8)), source: "", enabled: enabled, previous: nil, preferences: [:], development: false)
}
let plugins = try [plugin("new"), plugin("frequent"), plugin("recent"), plugin("old"), plugin("off", false)]
let usage = PluginUsage(root: root), now = Date()
assert(usage.ranked(plugins).count == 4)
for _ in 0..<5 { usage.record("local.frequent", now: now.addingTimeInterval(-3600)) }
usage.record("local.recent", now: now)
for _ in 0..<20 { usage.record("local.old", now: now.addingTimeInterval(-86400 * 365)) }
usage.record("local.off", now: now)
let reloaded = PluginUsage(root: root)
let ordered = reloaded.ranked(plugins, now: now).map { $0.manifest.id }
assert(ordered == ["local.frequent", "local.recent", "local.old", "local.new"])
let rows = reloaded.items(for: plugins) { _, command in ["custom-" + command.id] }
assert(rows.count == 8 && Set(rows.map(\\.id)).count == 8)
assert(rows[0].extensionID == "local.frequent" && rows[0].icon == "star")
assert(rows[1].icon == "app" && rows[1].subtitle?.contains("custom-two") == true)
assert(rows.allSatisfy { $0.actions.first?.type == "command.open" })
let withoutFrequent = reloaded.ranked(plugins.filter { $0.manifest.id != "local.frequent" })
assert(withoutFrequent.count == 3 && withoutFrequent[0].manifest.id == "local.recent")
try Data("invalid".utf8).write(to: root.appendingPathComponent("plugin-usage.json"))
assert(PluginUsage(root: root).ranked(plugins).count == 4)
print("PASS")
`);
    const binary = path.join(root, 'check');
    const build = spawnSync('swiftc', ['apps/macos/Sources/Models.swift', 'apps/macos/Sources/PluginUsage.swift', path.join(root, 'main.swift'), '-o', binary], { encoding: 'utf8' });
    assert.equal(build.status, 0, build.stderr);
    const result = spawnSync(binary, [root], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /PASS/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
