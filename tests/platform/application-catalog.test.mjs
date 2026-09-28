import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

test('catalog includes hidden app links and registered apps, deduplicates paths and skips nested helpers', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'launcher-app-catalog-'));
  try {
    fs.writeFileSync(path.join(dir, 'main.swift'), `
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let apps = root.appendingPathComponent("Applications")
try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
func app(_ path: String, id: String, schemes: [String] = []) throws -> URL {
    let url = root.appendingPathComponent(path)
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier":id,"CFBundleName":id,"CFBundlePackageType":"APPL","CFBundleURLTypes":[["CFBundleURLSchemes":schemes]]]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    return url
}
let safari = try app("System/Browser.app", id:"test.browser", schemes:["HTTP","https","http"])
let external = try app("Elsewhere/Other.app", id:"test.external", schemes:["https","http"])
_ = try app("Applications/Normal.app", id:"test.normal")
_ = try app("Applications/Normal.app/Contents/Helper.app", id:"test.helper")
_ = try app("Applications/.Hidden.app", id:"test.hidden")
try FileManager.default.createSymbolicLink(at:apps.appendingPathComponent(".Browser.app"), withDestinationURL:safari)
try FileManager.default.createSymbolicLink(at:apps.appendingPathComponent("Broken.app"), withDestinationURL:root.appendingPathComponent("Missing.app"))
let oldVersion = try app("Updater/Browser.app", id:"test.browser")
let catalog = ApplicationCatalog(roots:[apps], registeredApplications:{ [safari,external,external,oldVersion] })
let done = DispatchSemaphore(value:0)
catalog.list { entries in
    assert(Set(entries.map(\\.bundleIdentifier)) == Set(["test.browser","test.normal","test.external"]), entries.map { $0.bundleIdentifier + "=" + $0.url.path }.joined(separator: ","))
    assert(entries.count == 3)
    let browser = entries.first { $0.bundleIdentifier == "test.browser" }!
    assert(browser.url.path == safari.resolvingSymlinksInPath().standardizedFileURL.path, "Resolved application path must match")
    assert(browser.urlSchemes == ["http","https"])
    assert((browser.metadata["urlSchemes"] as? [String]) == ["http","https"])
    done.signal()
}
assert(done.wait(timeout:.now()+5) == .success)
print("PASS")
`);
    const binary = path.join(dir, 'check');
    const build = spawnSync('swiftc', ['apps/macos/Sources/ApplicationName.swift', 'apps/macos/Sources/ApplicationCatalog.swift', path.join(dir, 'main.swift'), '-o', binary], { encoding: 'utf8' });
    assert.equal(build.status, 0, build.stderr);
    const run = spawnSync(binary, [dir], { encoding: 'utf8', timeout: 10000 });
    assert.equal(run.status, 0, run.stderr);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
