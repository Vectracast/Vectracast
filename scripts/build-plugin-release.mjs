import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { pack, projectRoot } from "../packages/cli/bin/platform.mjs";

export function compareVersions(a, b) {
  const parse = (s) => {
    if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(s))
      throw Error("Invalid version: " + s);
    return s.split(".").map(BigInt);
  };
  const x = parse(a),
    y = parse(b);
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] > y[i] ? 1 : -1;
  return 0;
}
export function validateUpgrade(entry, previous) {
  if (!previous) return;
  const comparison = compareVersions(
    entry.manifest.version,
    previous.manifest.version,
  );
  if (comparison < 0) throw Error("Version downgrade: " + entry.manifest.id);
  if (comparison === 0 && entry.sha256 !== previous.sha256)
    throw Error(
      "Changed package requires a version bump: " + entry.manifest.id,
    );
}
export async function buildPluginRelease(directory, output, previousFile) {
  const version = JSON.parse(
    await fs.readFile(path.join(projectRoot, "package.json"), "utf8"),
  ).version;
  const previous = previousFile
    ? JSON.parse(await fs.readFile(previousFile, "utf8"))
    : { schemaVersion: 1, plugins: [] };
  if (previous.schemaVersion !== 1 || !Array.isArray(previous.plugins))
    throw Error("Invalid previous catalog");
  await fs.mkdir(output, { recursive: true });
  const plugins = [];
  for (const item of (
    await fs.readdir(directory, { withFileTypes: true })
  ).sort((a, b) => a.name.localeCompare(b.name))) {
    if (!item.isDirectory() || item.name.startsWith(".")) continue;
    const dir = path.join(directory, item.name);
    try {
      await fs.access(path.join(dir, "extension.json"));
    } catch {
      continue;
    }
    const { output: packed, manifest } = await pack(dir, { release: true });
    const data = await fs.readFile(packed);
    if (data.length >= 3_000_000)
      throw Error("Package exceeds host limit: " + manifest.id);
    let metadata = {};
    try {
      metadata = JSON.parse(
        await fs.readFile(path.join(dir, "catalog.json"), "utf8"),
      );
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    const categories = metadata.categories ?? [];
    if (
      !/^[A-Za-z0-9_-]{1,100}$/.test(item.name) ||
      !Array.isArray(categories) ||
      categories.length > 8 ||
      categories.some(
        (c) => !["productivity", "developer", "language"].includes(c),
      )
    )
      throw Error("Invalid catalog metadata: " + item.name);
    const entry = {
      sourceDirectory: item.name,
      categories,
      manifest,
      asset: path.basename(packed),
      sha256: createHash("sha256").update(data).digest("hex"),
      minimumAppVersion: version,
    };
    if (plugins.some((p) => p.manifest.id === manifest.id))
      throw Error("Duplicate plugin ID: " + manifest.id);
    validateUpgrade(
      entry,
      previous.plugins.find((p) => p.manifest.id === manifest.id),
    );
    await fs.copyFile(packed, path.join(output, entry.asset));
    plugins.push(entry);
  }
  if (!plugins.length) throw Error("No plugins found");
  const index = { schemaVersion: 1, plugins };
  await fs.writeFile(
    path.join(output, "index.json"),
    JSON.stringify(index, null, 2) + "\n",
  );
  await fs.writeFile(
    path.join(output, "SHA256SUMS"),
    plugins.map((p) => `${p.sha256}  ${p.asset}`).join("\n") + "\n",
  );
  return index;
}
if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const [dir, out, previous] = process.argv.slice(2);
  if (!dir || !out)
    throw Error(
      "Usage: build-plugin-release.mjs <plugins directory> <output directory> [previous index]",
    );
  const index = await buildPluginRelease(
    path.resolve(dir),
    path.resolve(out),
    previous,
  );
  console.log(`Packaged ${index.plugins.length} plugins and index.json`);
}
