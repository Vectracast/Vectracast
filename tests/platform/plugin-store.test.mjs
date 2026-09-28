import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { pack, validateManifest } from "../../packages/cli/bin/platform.mjs";
const built = await pack("extensions/plugin-store");
const pkg = JSON.parse(fs.readFileSync(built.output));
const extension = vm.runInNewContext(pkg.source + "\nExtension.default", {});
const base = {
  handle: "opaque-1",
  manifest: {
    id: "test.calc",
    name: "计算器",
    version: "1.10.0",
    description: "精确计算",
    icon: "equal.square",
    commands: [{ id: "calculate", title: "计算", keywords: ["calc"] }],
  },
  permissions: "写入剪贴板",
  minimumAppVersion: "0.7.0",
  compatible: true,
  sourceURL: "https://github.com/test/plugins/tree/v1/calculator",
  readmeURL: "https://github.com/test/plugins/tree/v1/calculator#readme",
  releaseNotes: "真实更新说明",
  categories: ["developer"],
};
async function query(query = "", plugins = [base], filter = "all") {
  return JSON.parse(
    JSON.stringify(
      await extension.commands[0].query({
        query,
        filter,
        preferences: {},
        catalog: {
          list: async (...args) => { assert.equal(args.length, 0); return { repository: "Vectracast/Vectracast-Plugins", plugins }; },
        },
      }),
    ),
  ).items;
}
test("store owns search, categories, installed filtering and numeric update status", async () => {
  assert.equal((await query("计算"))[0].id, "test.calc");
  assert.equal((await query("CALCULATE"))[0].id, "test.calc");
  assert.equal((await query("test.calc"))[0].id, "test.calc");
  assert.equal((await query("", [base], "language"))[0].id, "empty");
  assert.equal((await query("", [base], "installed"))[0].id, "empty");
  const older = { ...base, installedVersion: "1.9.0" };
  const rows = await query("", [older], "installed");
  assert.equal(rows[0].group, "可更新");
  assert.equal(rows[0].actions[1].title, "更新插件");
  const current = (
    await query("", [{ ...base, installedVersion: "1.10.0" }])
  )[0];
  assert.equal(current.group, "已安装");
  assert.ok(!current.actions.some((a) => a.type === "catalog.install"));
  const incompatible = (await query("", [{ ...base, compatible: false }]))[0];
  assert.ok(!incompatible.actions.some((a) => a.type === "catalog.install"));
});
test("store emits generic details and issued installation handles with source links", async () => {
  const [row] = await query();
  assert.equal(row.actions[0].type, "view.detail");
  assert.equal(row.actions[1].type, "catalog.install");
  assert.equal(row.actions[1].text, row.catalogID);
  assert.match(row.preview.text, /真实更新说明/);
  assert.match(row.preview.text, /calculate/);
  assert.match(row.preview.text, /写入剪贴板/);
  assert.equal(row.actions.find((a) => a.id === "readme").text, base.readmeURL);
  assert.equal(row.actions.find((a) => a.id === "source").text, base.sourceURL);
  assert.equal(
    row.actions.find((a) => a.id === "refresh").type,
    "catalog.refresh",
  );
  assert.ok(!JSON.stringify(row).includes("Downloads"));
});
test("store failure stays a plugin result with retry and permissions remain explicit", async () => {
  const result = await extension.commands[0].query({
    query: "",
    filter: "all",
    preferences: {},
    catalog: {
      list: async () => {
        throw new Error("离线");
      },
    },
  });
  assert.equal(result.items[0].id, "unavailable");
  assert.match(result.items[0].subtitle, /离线/);
  validateManifest(pkg.manifest);
  assert.ok(!pkg.manifest.preferences?.some((p) => p.name === "repository"));
  assert.equal(pkg.manifest.commands[0].presentation, "list");
  assert.deepEqual(pkg.manifest.permissions.catalog, ["read", "install"]);
  assert.throws(() =>
    validateManifest({
      ...pkg.manifest,
      permissions: { catalog: ["install"] },
    }),
  );
  assert.throws(() =>
    validateManifest({ ...pkg.manifest, permissions: { catalog: ["remove"] } }),
  );
  assert.throws(() =>
    validateManifest({ ...pkg.manifest, permissions: { browser: ["file"] } }),
  );
});
