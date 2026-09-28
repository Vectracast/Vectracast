import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

test('native debounce coalesces input, respects longer delays and cancels pending queries', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'launcher-debounce-'));
  try {
    fs.writeFileSync(path.join(dir, 'main.swift'), `
import Foundation
let rapid = QueryDebouncer(), cancelled = QueryDebouncer(), longer = QueryDebouncer()
let entry = QueryDebouncer()
var opened = 0, stale = false
entry.schedule(requestedDelayMs: 200) { stale = true }
entry.schedule(requestedDelayMs: 5000, immediate: true) { opened += 1 }
assert(opened == 1, "Explicit command entry must run immediately")
var deliveries: [String] = []
let start = Date()
var rapidTime = 0.0, longerTime = 0.0
for (index, input) in ["0", "0x", "0xff", "0xfff404"].enumerated() {
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.05) {
        rapid.schedule(requestedDelayMs: 80) {
            deliveries.append(input)
            rapidTime = Date().timeIntervalSince(start)
        }
    }
}
cancelled.schedule(requestedDelayMs: 0) { deliveries.append("cancelled") }
DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { cancelled.cancel() }
longer.schedule(requestedDelayMs: 500) {
    deliveries.append("longer")
    longerTime = Date().timeIntervalSince(start)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
    assert(!stale && opened == 1, "Immediate entry must cancel old pending input")
    let result: [String: Any] = ["deliveries": deliveries, "rapidTime": rapidTime, "longerTime": longerTime]
    print(String(data: try! JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
    exit(0)
}
RunLoop.main.run()
`);
    const binary = path.join(dir, 'debounce');
    const build = spawnSync('swiftc', ['apps/macos/Sources/QueryDebouncer.swift', path.join(dir, 'main.swift'), '-o', binary], {encoding:'utf8', timeout:30000});
    assert.equal(build.status, 0, build.stderr);
    const run = spawnSync(binary, [], {encoding:'utf8', timeout:5000});
    assert.equal(run.status, 0, run.stderr);
    const result = JSON.parse(run.stdout);
    assert.deepEqual(result.deliveries, ['0xfff404', 'longer']);
    assert.ok(result.rapidTime >= 0.34, JSON.stringify(result));
    assert.ok(result.longerTime >= 0.49, JSON.stringify(result));
  } finally { fs.rmSync(dir, {recursive:true, force:true}); }
});
