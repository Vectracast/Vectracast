import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

test('native image loading yields main thread, coalesces requests and caches bounded thumbnails', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'launcher-image-loader-'));
  try {
    fs.writeFileSync(path.join(directory, 'main.swift'), `
import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let url = root.appendingPathComponent("fixture.png")
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 1200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
try bitmap.representation(using: .png, properties: [:])!.write(to: url)
let loader = HistoryImageLoader()
var images: [NSImage] = []
let start = Date()
for _ in 0..<40 {
    loader.load(url: url, maxPixels: 80) { image in
        assert(Thread.isMainThread)
        images.append(image!)
    }
}
assert(images.isEmpty, "Cold decoding must not block the main thread")
let deadline = Date().addingTimeInterval(10)
while images.count < 40 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
assert(images.count == 40)
assert(images.allSatisfy { $0 === images[0] }, "Concurrent requests must share a decoded image")
assert(images[0].size.width <= 80 && images[0].size.height <= 80)
var cached: NSImage?
loader.load(url: url, maxPixels: 80) { cached = $0 }
assert(cached === images[0], "A warm thumbnail must be immediately available")
var preview: NSImage?
loader.load(url: url, maxPixels: 1000) { preview = $0 }
while preview == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
assert(preview != nil && preview !== images[0] && preview!.size.width == 1000)
var missingFinished = false
loader.load(url: root.appendingPathComponent("missing.png"), maxPixels: 80) { assert($0 == nil); missingFinished = true }
while !missingFinished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
assert(missingFinished)
print("PASS: 40 coalesced thumbnails + cached revisit + preview + missing asset; \\(Int(Date().timeIntervalSince(start) * 1000)) ms")
`);
    const compile = spawnSync('swiftc', ['apps/macos/Sources/HistoryImageLoader.swift', path.join(directory, 'main.swift'), '-o', path.join(directory, 'check')], { encoding: 'utf8' });
    assert.equal(compile.status, 0, compile.stderr);
    const result = spawnSync(path.join(directory, 'check'), [directory], { encoding: 'utf8', timeout: 15000 });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    console.log(result.stdout.trim());
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test('history image cache honors deletion, clear, expiry and revoked permissions', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'launcher-image-access-'));
  try {
    fs.writeFileSync(path.join(directory, 'stubs.swift'), `
import Foundation
struct LauncherError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
struct InstalledExtension {
    struct Manifest { struct Permissions { var clipboard: [String]? = ["history", "history-images", "write"] }; var id = "test.history"; var permissions = Permissions() }
    var enabled = true; var manifest = Manifest()
}
final class ExtensionStore {
    static var revision = 0
    static var info = InstalledExtension()
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    func run(_ sql: String) throws -> [[String: String]] { [["revision": String(Self.revision)]] }
    func list() -> [InstalledExtension] { [Self.info] }
}
`);
    fs.writeFileSync(path.join(directory, 'main.swift'), `
import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let archive = try ClipboardHistoryArchive(url: ClipboardHistory.archiveURL(root: root, extensionID: "test.history"))
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let data = bitmap.representation(using: .png, properties: [:])!
func add() throws -> String { try archive.appendImage(png: data, width: 800, height: 600, source: "Fixture"); return archive.entries[0].id }
func wait(_ done: () -> Bool) { let deadline = Date().addingTimeInterval(5); while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }; assert(done()) }
let service = ClipboardHistory()
var id = try add()
var done = false
service.loadImage("test.history", entryID: id) { assert($0 == nil, "Clear during decode must reject stale completion"); done = true }
try service.clear("test.history")
wait { done }
assert(try service.list("test.history").isEmpty)
id = try add(); done = false
service.loadImage("test.history", entryID: id) { assert($0 != nil); done = true }
wait { done }
ExtensionStore.info.enabled = false; ExtensionStore.revision += 1
done = false
service.loadImage("test.history", entryID: id) { assert($0 == nil, "Cached image must not bypass disable"); done = true }
assert(done)
ExtensionStore.info.enabled = true; ExtensionStore.info.manifest.permissions.clipboard = ["history"]; ExtensionStore.revision += 1
done = false
service.loadImage("test.history", entryID: id) { assert($0 == nil, "Image permission must be enforced on warm cache"); done = true }
assert(done)
ExtensionStore.info.manifest.permissions.clipboard = ["history", "history-images"]; ExtensionStore.revision += 1
try service.remove("test.history", entry: id)
service.loadImage("test.history", entryID: id) { assert($0 == nil) }
id = try add()
let url = archive.url
var entries = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
entries[0]["timestamp"] = 0
try JSONSerialization.data(withJSONObject: entries).write(to: url, options: .atomic)
assert(try service.list("test.history").isEmpty)
print("PASS: stale decode, cached disable, revoked image permission, delete and expired archive")
`);
    // assert autoclosures cannot throw; evaluate the throwing read first.
    const main = path.join(directory, 'main.swift');
    fs.writeFileSync(main, fs.readFileSync(main, 'utf8').replaceAll('assert(try service.list("test.history").isEmpty)', 'do { let entries = try service.list("test.history"); assert(entries.isEmpty) }'));
    const compile = spawnSync('swiftc', ['apps/macos/Sources/HistoryImageLoader.swift', 'apps/macos/Sources/ClipboardHistoryArchive.swift', 'apps/macos/Sources/ClipboardHistory.swift', path.join(directory, 'stubs.swift'), main, '-o', path.join(directory, 'check')], { encoding: 'utf8' });
    assert.equal(compile.status, 0, compile.stderr);
    const result = spawnSync(path.join(directory, 'check'), [directory], { encoding: 'utf8', timeout: 15000 });
    assert.equal(result.status, 0, result.stderr + result.stdout);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
