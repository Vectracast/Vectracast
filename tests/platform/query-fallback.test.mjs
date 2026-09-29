import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

test('host lists enabled input-capable commands with the original query attached for selection', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'vectracast-query-fallback-'));
  try {
    fs.writeFileSync(path.join(directory, 'main.swift'), `
import Foundation
func extensionInfo(_ id: String, _ name: String, _ enabled: Bool, _ command: String, _ icon: String) throws -> InstalledExtension {
    let json = """
    {"manifestVersion":1,"id":"local.\\(id)","name":"\\(name)","version":"1.0.0","description":"","runtime":"standard-js","sdk":"0.1","icon":"globe","entry":"src/index.ts","commands":[{"id":"\\(command)","title":"\\(name)","keywords":[],"inputMode":"query","icon":"\\(icon)"}],"permissions":{},"preferences":[]}
    """
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    return InstalledExtension(manifest: manifest, source: "", enabled: enabled, previous: nil, preferences: [:], development: false)
}
let eligible = try extensionInfo("web", "网页搜索", true, "search", "assets/search.png")
let disabled = try extensionInfo("off", "停用插件", false, "run", "globe")
let rows = QueryFallback.entries(for: [eligible, disabled], input: "  README  ")
assert(rows.count == 2)
assert(rows[0].groupHeading == true && rows[0].title.contains("README"))
assert(rows[1].title == "网页搜索" && rows[1].subtitle?.contains("使用当前输入") == true)
assert(rows[1].icon == "assets/search.png" && rows[1].extensionID == "local.web")
assert(rows[1].actions.first?.type == "command.input" && rows[1].actions.first?.text == "search")
assert(QueryFallback.entries(for: [disabled], input: "README").isEmpty)
assert(QueryFallback.entries(for: [eligible], input: " ").isEmpty)
print("PASS")
`);
    const compile = spawnSync('swiftc', ['apps/macos/Sources/Models.swift', 'apps/macos/Sources/QueryFallback.swift', path.join(directory, 'main.swift'), '-o', path.join(directory, 'check')], { encoding: 'utf8' });
    assert.equal(compile.status, 0, compile.stderr);
    const run = spawnSync(path.join(directory, 'check'), [], { encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr + run.stdout);
    assert.match(run.stdout, /PASS/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
