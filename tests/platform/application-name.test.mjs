import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

test('native app names follow requested language, retain English search terms and fall back safely', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'launcher-app-name-'));
  try {
    fs.writeFileSync(path.join(dir, 'main.swift'), `
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
func fixture(_ filename: String, raw: [String: Any], localized: [String: [String: String]]) throws -> Bundle {
    let url = root.appendingPathComponent(filename + ".app")
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var info = raw; info["CFBundleIdentifier"] = "fixture." + filename; info["CFBundlePackageType"] = "APPL"; info["CFBundleDevelopmentRegion"] = "en"
    info["CFBundleLocalizations"] = Array(localized.keys)
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    for (language, strings) in localized {
        let folder = contents.appendingPathComponent("Resources/" + language + ".lproj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0).write(to: folder.appendingPathComponent("InfoPlist.strings"))
    }
    return Bundle(url: url)!
}
let bundle = try fixture("WeChat", raw: ["CFBundleDisplayName":"WeChat", "CFBundleName":"WeChat"], localized: ["en":["CFBundleDisplayName":"WeChat"], "zh-Hans":["CFBundleDisplayName":"微信"], "zh-Hant":["CFBundleDisplayName":"WeChat Traditional"]])
let chinese = ApplicationName.resolve(bundle, preferredLanguages: ["zh-Hans-CN"])
assert(chinese.name == "微信")
assert(chinese.searchTerms.contains("WeChat") && chinese.searchTerms.contains("weixin"))
assert(chinese.searchTerms.contains("wei xin") && chinese.searchTerms.contains("wx"))
let tools = try fixture("Developer", raw: [:], localized: ["zh-Hans":["CFBundleDisplayName":"微信开发者工具"]])
let toolsName = ApplicationName.resolve(tools, preferredLanguages: ["zh-Hans"])
assert(toolsName.searchTerms.contains("wxkfzgj") && toolsName.searchTerms.contains("weixinkaifazhegongju"))
assert(ApplicationName.resolve(bundle, preferredLanguages: ["en-US"]).name == "WeChat")
assert(ApplicationName.resolve(bundle, preferredLanguages: ["zh-Hant-TW"]).name == "WeChat Traditional")
let short = try fixture("Short", raw: ["CFBundleDisplayName":"Raw Name"], localized: ["zh-Hans":["CFBundleName":"中文短名"]])
assert(ApplicationName.resolve(short, preferredLanguages: ["zh-Hans"]).name == "中文短名")
let plain = try fixture("Plain", raw: ["CFBundleName":"Bundle Name"], localized: [:])
assert(ApplicationName.resolve(plain, preferredLanguages: ["zh-Hans"]).name == "Bundle Name")
let missing = try fixture("Fallback", raw: [:], localized: [:])
assert(ApplicationName.resolve(missing, preferredLanguages: ["zh-Hans"]).name == "Fallback")
let empty = try fixture("Blank", raw: ["CFBundleDisplayName":"", "CFBundleName":"Raw Fallback"], localized: ["zh-Hans":["CFBundleDisplayName":"  "]])
assert(ApplicationName.resolve(empty, preferredLanguages: ["zh-Hans"]).name == "Raw Fallback")
let system = try fixture("SystemNotes", raw: ["CFBundleDisplayName":"Notes"], localized: ["zh_CN":["placeholder":"unused"]])
let resourceURL = system.resourceURL!
try FileManager.default.removeItem(at: resourceURL.appendingPathComponent("zh_CN.lproj/InfoPlist.strings"))
try PropertyListSerialization.data(fromPropertyList: ["zh_CN":["CFBundleDisplayName":"备忘录"]], format: .binary, options: 0).write(to: resourceURL.appendingPathComponent("InfoPlist.loctable"))
let notes = ApplicationName.resolve(system, preferredLanguages: ["zh-Hans-CN"])
assert(notes.name == "备忘录" && notes.searchTerms.contains("bwl"))
print("PASS")
`);
    const binary = path.join(dir, 'check');
    const build = spawnSync('swiftc', ['apps/macos/Sources/ApplicationName.swift', path.join(dir, 'main.swift'), '-o', binary], { encoding: 'utf8' });
    assert.equal(build.status, 0, build.stderr);
    const run = spawnSync(binary, [dir], { encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
