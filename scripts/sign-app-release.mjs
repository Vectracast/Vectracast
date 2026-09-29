import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { execFileSync } from "node:child_process";
import { createPublicKey, verify } from "node:crypto";
import { sparkleDirectory } from "./prepare-sparkle.mjs";

// The public key ships in the app. Private key material is only passed on stdin,
// never in command arguments, build artifacts, or a repository file.
export async function signAppRelease({ archive, notes, output, version, buildNumber }) {
  const config = JSON.parse(await fs.readFile("assets/update-signing.json", "utf8"));
  const signingKey = process.env.SPARKLE_PRIVATE_KEY;
  if (process.env.CI && !signingKey) throw Error("SPARKLE_PRIVATE_KEY is required for a release");
  const sign = (file, extra = []) => execFileSync(path.join(sparkleDirectory, "bin/sign_update"), [
    ...(signingKey ? ["--ed-key-file", "-"] : ["--account", config.keychainAccount]),
    ...extra, file,
  ], { input: signingKey ? signingKey + "\n" : undefined, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] });
  const signature = sign(archive, ["-p"]).trim();
  const publicKey = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(config.publicKey, "base64")]), format: "der", type: "spki" });
  if (!verify(null, await fs.readFile(archive), publicKey, Buffer.from(signature, "base64"))) throw Error("Signing key does not match the embedded public key");
  const staging = await fs.mkdtemp(path.join(os.tmpdir(), "vectracast-appcast-"));
  try {
    const name = path.basename(archive);
    await fs.copyFile(archive, path.join(staging, name));
    await fs.copyFile(notes, path.join(staging, name.replace(/\.zip$/, ".md")));
    execFileSync(path.join(sparkleDirectory, "bin/generate_appcast"), [
      ...(signingKey ? ["--ed-key-file", "-"] : ["--account", config.keychainAccount]),
      "--download-url-prefix", `https://vectracast-api.fix030.com/v1/assets/app/v${version}/`,
      "--embed-release-notes", "--maximum-deltas", "0", "--versions", String(buildNumber), staging,
    ], { input: signingKey ? signingKey + "\n" : undefined, stdio: ["pipe", "pipe", "pipe"] });
    const feed = path.join(staging, "appcast.xml");
    // generate_appcast signs feeds because SURequireSignedFeed is embedded in the app.
    await fs.copyFile(feed, output);
  } finally { await fs.rm(staging, { recursive: true, force: true }); }
}
