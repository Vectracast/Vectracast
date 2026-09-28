import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

test('command entry accepts aliases, IDs, Chinese names and arguments without ambiguous routing', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'launcher-command-entry-'));
  try {
    fs.writeFileSync(path.join(dir, 'main.swift'), `
import Foundation
let history = CommandEntryMatcher.Candidate(key: "clipboard/history", commandID: "history", title: "剪贴板历史", aliases: ["cb"], extensionName: "历史记录")
for input in ["cb", "CB", "history", "HiStOrY", "剪贴板历史", "历史记录", "  history  "] {
    let result = CommandEntryMatcher.match(input, candidates: [history])
    assert(result?.key == history.key && result?.query == "", input)
}
for input in ["CB apple", "history apple", "剪贴板历史 apple", "历史记录 apple"] {
    assert(CommandEntryMatcher.match(input, candidates: [history])?.query == "apple")
}
assert(CommandEntryMatcher.match("historybook", candidates: [history]) == nil)
assert(CommandEntryMatcher.match("剪贴板历", candidates: [history]) == nil)
assert(CommandEntryMatcher.match("cb", candidates: []) == nil)
let renamed = CommandEntryMatcher.Candidate(key: history.key, commandID: "history", title: "剪贴板历史", aliases: ["clip"])
assert(CommandEntryMatcher.match("cb", candidates: [renamed]) == nil)
assert(CommandEntryMatcher.match("history", candidates: [renamed])?.key == history.key)
let other = CommandEntryMatcher.Candidate(key: "other/history", commandID: "history", title: "剪贴板历史", aliases: ["other"])
assert(CommandEntryMatcher.match("history", candidates: [history, other]) == nil)
assert(CommandEntryMatcher.match("剪贴板历史", candidates: [history, other]) == nil)
assert(CommandEntryMatcher.match("cb", candidates: [history, other])?.key == history.key)
let alias = CommandEntryMatcher.Candidate(key: "alias", commandID: "open", title: "Open", aliases: ["history"])
assert(CommandEntryMatcher.match("history", candidates: [history, alias])?.key == "alias")
let spaced = CommandEntryMatcher.Candidate(key: "spaced", commandID: "list", title: "Clipboard History", aliases: [])
assert(CommandEntryMatcher.match("clipboard history   hello world", candidates: [spaced])?.query == "hello world")
let longer = CommandEntryMatcher.Candidate(key: "long", commandID: "extended", title: "Clipboard History Images", aliases: [])
assert(CommandEntryMatcher.match("Clipboard History Images", candidates: [spaced, longer])?.key == "long")
print("PASS")
`);
    const binary = path.join(dir, 'check');
    const build = spawnSync('swiftc', ['apps/macos/Sources/CommandEntryMatcher.swift', path.join(dir, 'main.swift'), '-o', binary], { encoding: 'utf8' });
    assert.equal(build.status, 0, build.stderr);
    const run = spawnSync(binary, [], { encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
