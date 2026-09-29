import fs from "node:fs/promises";
import path from "node:path";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";

export const sparkleVersion = "2.10.0";
export const sparkleDirectory = path.resolve(`build/dependencies/sparkle-${sparkleVersion}`);
const digest = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c";
export async function prepareSparkle() {
  const archive = path.resolve(`build/dependencies/Sparkle-${sparkleVersion}.tar.xz`);
  await fs.mkdir(path.dirname(archive), { recursive: true });
  let data = await fs.readFile(archive).catch(() => null);
  if (!data || createHash("sha256").update(data).digest("hex") !== digest) {
    const response = await fetch(`https://github.com/sparkle-project/Sparkle/releases/download/${sparkleVersion}/Sparkle-${sparkleVersion}.tar.xz`, { signal: AbortSignal.timeout(120_000) });
    if (!response.ok) throw Error(`Sparkle download failed: ${response.status}`);
    data = Buffer.from(await response.arrayBuffer());
    if (createHash("sha256").update(data).digest("hex") !== digest) throw Error("Sparkle checksum mismatch");
    await fs.writeFile(archive, data);
  }
  // Re-extract the verified archive; do not trust previously extracted build files.
  await fs.rm(sparkleDirectory, { recursive: true, force: true });
  await fs.mkdir(sparkleDirectory, { recursive: true });
  execFileSync("tar", ["-xJf", archive, "-C", sparkleDirectory]);
}
if (process.argv[1] === new URL(import.meta.url).pathname) await prepareSparkle();
