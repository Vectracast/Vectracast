import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
if (!process.argv[2])
  throw Error(
    "Usage: node scripts/prepare-plugin-repository.mjs <new directory>",
  );
const output = path.resolve(process.argv[2]);
try {
  await fs.access(output);
  throw Error("Destination already exists; choose a new directory.");
} catch (e) {
  if (e.code !== "ENOENT") throw e;
}
await fs.mkdir(output, { recursive: true });
for (const item of await fs.readdir(path.join(root, "extensions"), {
  withFileTypes: true,
})) {
  if (!item.isDirectory() || item.name.startsWith(".")) continue;
  const source = path.join(root, "extensions", item.name);
  try {
    await fs.access(path.join(source, "extension.json"));
  } catch {
    continue;
  }
  await fs.cp(source, path.join(output, item.name), {
    recursive: true,
    filter: (p) =>
      !["dist", "node_modules", ".git", ".DS_Store"].includes(
        path.basename(p),
      ) && !path.basename(p).startsWith(".env"),
  });
}
await fs.cp(path.join(root, "repository-templates/plugins"), output, {
  recursive: true,
});
await fs.copyFile(path.join(root, "LICENSE"), path.join(output, "LICENSE"));
console.log(
  "Plugin repository prepared at " +
    output +
    "; original sources were not moved.",
);
