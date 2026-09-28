import fs from "node:fs/promises";
import path from "node:path";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
const pkg = JSON.parse(await fs.readFile("package.json", "utf8"));
if (!/^\d+\.\d+\.\d+$/.test(pkg.version))
  throw Error("Invalid application version");
if (
  process.env.GITHUB_REF_NAME &&
  process.env.GITHUB_REF_NAME !== `v${pkg.version}`
)
  throw Error("Tag must match package.json version");
const output = path.resolve("build/release");
await fs.mkdir(output, { recursive: true });
const name = `Vectracast-${pkg.version}-macOS-arm64.zip`;
execFileSync("codesign", [
  "--verify",
  "--deep",
  "--strict",
  "build/Vectracast.app",
]);
execFileSync("/usr/bin/ditto", [
  "-c",
  "-k",
  "--sequesterRsrc",
  "--keepParent",
  "build/Vectracast.app",
  path.join(output, name),
]);
const sha = createHash("sha256")
  .update(await fs.readFile(path.join(output, name)))
  .digest("hex");
await fs.writeFile(path.join(output, "SHA256SUMS"), `${sha}  ${name}\n`);
console.log(path.join(output, name));
