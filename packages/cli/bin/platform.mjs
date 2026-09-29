#!/usr/bin/env node
import fs from "node:fs/promises";
import { watch } from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { isBuiltin } from "node:module";
import { build } from "esbuild";

export const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const appBinary = path.join(projectRoot, "build/Vectracast.app/Contents/MacOS/Vectracast");
const sdkPath = path.join(projectRoot, "packages/sdk/src/index.ts");

export function validateManifest(m) {
  if (m.manifestVersion !== 1 || m.runtime !== "standard-js" || m.sdk !== "0.1") throw new Error("Unsupported manifest, runtime, or SDK version");
  if (!/^[a-z][a-z0-9-]{0,40}\.[a-z][a-z0-9-]{0,50}$/.test(m.id)) throw new Error("Invalid extension id");
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(m.version)) throw new Error("Use a numeric major.minor.patch version");
  if (!Array.isArray(m.commands) || !m.commands.length) throw new Error("No commands declared");
  if (typeof m.entry !== "string" || path.isAbsolute(m.entry) || m.entry.split(/[\\/]/).includes("..")) throw new Error("Entry must be inside extension directory");
  if (!m.permissions || Object.keys(m.permissions).some(k => !["network", "clipboard", "applications", "catalog", "browser", "files"].includes(k))) throw new Error("Unsupported permission");
  if (m.permissions.files !== undefined && (!Array.isArray(m.permissions.files) || m.permissions.files.some(x=>!["search","open"].includes(x)) || (m.permissions.files.includes("open") && !m.permissions.files.includes("search")))) throw new Error("Invalid files permissions");
  if (m.permissions.applications !== undefined && (!Array.isArray(m.permissions.applications) || m.permissions.applications.some(x=>!["read","open"].includes(x)) || (m.permissions.applications.includes("open") && !m.permissions.applications.includes("read")))) throw new Error("Invalid applications permissions");
  if (m.permissions.clipboard !== undefined && (!Array.isArray(m.permissions.clipboard) || m.permissions.clipboard.some(x => !["write", "history", "history-images", "paste"].includes(x)))) throw new Error("Invalid clipboard permissions");
  if (m.permissions.clipboard?.includes("history-images") && !m.permissions.clipboard.includes("history")) throw new Error("Image history requires history permission");
  if (m.permissions.clipboard?.includes("paste") && !m.permissions.clipboard.includes("write")) throw new Error("Paste requires write permission");
  if (m.permissions.catalog !== undefined && (!Array.isArray(m.permissions.catalog) || m.permissions.catalog.some(x=>!["read","install"].includes(x)) || (m.permissions.catalog.includes("install") && !m.permissions.catalog.includes("read")))) throw new Error("Invalid catalog permissions");
  if (m.permissions.browser !== undefined && (!Array.isArray(m.permissions.browser) || m.permissions.browser.some(x=>x!=="open"))) throw new Error("Invalid browser permissions");
  const ids = new Set(), keys = new Set();
  for (const c of m.commands) {
    if (!/^[a-z][a-z0-9-]{0,50}$/.test(c.id) || ids.has(c.id)) throw new Error("Invalid or duplicate command id");
    ids.add(c.id);
    if (![undefined, "detail", "list"].includes(c.presentation)) throw new Error("Invalid presentation");
    if (c.searchPlaceholder !== undefined && (typeof c.searchPlaceholder !== "string" || c.searchPlaceholder.length > 80)) throw new Error("Invalid search placeholder");
    if (c.filters !== undefined && (!Array.isArray(c.filters) || c.filters.length > 10 || c.filters.some(f => typeof f.id !== "string" || f.id.length > 30 || typeof f.title !== "string" || !f.title.length || f.title.length > 30) || new Set(c.filters.map(f => f.id)).size !== c.filters.length)) throw new Error("Invalid filters");
    if (c.acceptsEmptyQuery !== undefined && typeof c.acceptsEmptyQuery !== "boolean") throw new Error("Invalid acceptsEmptyQuery");
    if (![undefined, "keyword", "query"].includes(c.inputMode)) throw new Error("Invalid command inputMode");
    if (!Array.isArray(c.keywords) || (!c.keywords.length && c.inputMode !== "query")) throw new Error("Command needs a keyword or query inputMode");
    if (c.debounceMs !== undefined && (!Number.isInteger(c.debounceMs) || c.debounceMs < 0 || c.debounceMs > 5000)) throw new Error("Invalid debounceMs");
    for (const k of c.keywords) {
      if (!/^[a-z][a-z0-9-]{0,20}$/.test(k) || keys.has(k)) throw new Error("Invalid or duplicate keyword");
      keys.add(k);
    }
  }
}

export async function pack(directory, { release = false } = {}) {
  const dir = path.resolve(directory);
  const manifest = JSON.parse(await fs.readFile(path.join(dir, "extension.json"), "utf8"));
  validateManifest(manifest);
  const entry = await fs.realpath(path.join(dir, manifest.entry));
  const realDir = await fs.realpath(dir);
  if (!entry.startsWith(realDir + path.sep)) throw new Error("Entry symlink escapes extension directory");
  const result = await build({
    entryPoints: [entry], bundle: true, write: false, format: "iife", globalName: "Extension", platform: "neutral", target: "es2022",
    sourcemap: release ? false : "inline", minify: release,
    ...(release ? { tsconfig: path.join(projectRoot, "tsconfig.platform.json") } : {}),
    sourcesContent: true, alias: { "@platform/sdk": sdkPath },
    plugins: [{ name: "standard-runtime", setup(build) {
      build.onResolve({ filter: /.*/ }, args => {
        if (isBuiltin(args.path)) return { errors: [{ text: `Node built-in '${args.path}' is unavailable. Use the host SDK.` }] };
      });
    } }],
  });
  const source = result.outputFiles[0].text;
  if (Buffer.byteLength(source) > 2_000_000) throw new Error("Bundle exceeds 2 MB");
  const pkg = { format: 1, manifest, source, sha256: createHash("sha256").update(source).digest("hex") };
  const output = path.join(dir, "dist", `${manifest.id}-${manifest.version}.launcher-extension`);
  await fs.mkdir(path.dirname(output), { recursive: true });
  await fs.writeFile(output, JSON.stringify(pkg));
  return { output, manifest };
}

function native(args) {
  const result = spawnSync(appBinary, args, { stdio: "inherit", env: process.env });
  if (result.error) throw new Error("Build the app first: npm run app:build");
  if (result.status !== 0) throw new Error(`Host exited with status ${result.status}`);
}

async function main() {
  const [command = "help", ...args] = process.argv.slice(2);
  const positional = args.filter(a => !a.startsWith("--"));
  if (command === "create") {
    const destination = path.resolve(positional[0] || "my-extension");
    try { await fs.access(destination); throw new Error("Destination already exists"); } catch (error) { if (error.code !== "ENOENT") throw error; }
    const useYoudao = args.includes("--youdao");
    await fs.cp(path.join(projectRoot, "extensions", useYoudao ? "youdao" : "text-tools"), destination, { recursive: true, filter: src => !src.includes(`${path.sep}dist`) });
    const mpath = path.join(destination, "extension.json");
    const m = JSON.parse(await fs.readFile(mpath, "utf8"));
    const slug = path.basename(destination).toLowerCase().replace(/[^a-z0-9-]/g, "-");
    if (!/^[a-z]/.test(slug)) throw new Error("Project name must start with a letter");
    m.id = "local." + slug;
    await fs.writeFile(mpath, JSON.stringify(m, null, 2) + "\n");
    await fs.writeFile(path.join(destination, "README.md"), `# ${m.name}\n\nSDK 0.1 extension. Configure the keyword in extension.json before installing alongside another copy.\n\nFrom the platform checkout:\n\n\`node packages/cli/bin/platform.mjs dev ${destination} --accept-permissions\`\n`);
    console.log(`Created ${destination}`);
  } else if (command === "pack" || command === "validate") {
    const result = await pack(positional[0] || "."); console.log(result.output);
  } else if (command === "install") {
    if (!positional[0]) throw new Error("Usage: platform install <package> --accept-permissions");
    native(["--install", path.resolve(positional[0]), ...(args.includes("--accept-permissions") ? ["--accept-permissions"] : [])]);
  } else if (command === "dev") {
    const dir = path.resolve(positional[0] || ".");
    const home = process.env.LAUNCHER_HOME || path.join(os.homedir(), 'Library/Application Support/Launcher');
    const statusDir = path.join(home, 'development');
    await fs.mkdir(statusDir, {recursive:true});
    const statusFile = path.join(statusDir, createHash('sha256').update(dir).digest('hex').slice(0,16) + '.json');
    let building = false, queued = false, initial = true, dirty = false, autoReload = true, stopped = false;
    const status = async (state, message = '') => {
      let id = path.basename(dir);
      try { id = JSON.parse(await fs.readFile(path.join(dir, 'extension.json'), 'utf8')).id || id; } catch {}
      const temporary = statusFile + '.' + process.hrtime.bigint() + '.tmp';
      await fs.writeFile(temporary, JSON.stringify({extension:id, state, message:String(message).slice(0,12000), updatedAt:Date.now()}));
      await fs.rename(temporary, statusFile);
    };
    const rebuild = async () => {
      if (stopped) return;
      if (building) { queued = true; return; } building = true;
      dirty = false;
      try {
        await status('building');
        const { output } = await pack(dir);
        native(["--install", output, "--development", ...(initial && args.includes("--accept-permissions") ? ["--accept-permissions"] : [])]);
        initial = false;
        console.log("Reloaded. Type the keyword in Vectracast. 'platform inspect' explains the debugger.");
        await status('ready');
      } catch (e) { console.error(e.message); await status('error', e.message); }
      finally { building = false; if (queued) { queued = false; void rebuild(); } }
    };
    try { autoReload = JSON.parse(await fs.readFile(path.join(home, 'preferences.json'), 'utf8')).developerAutoReload !== false; } catch {}
    let debounce;
    // Start watching before the first build can announce readiness; immediate edits must not be lost.
    const watcher = watch(dir, { recursive: true }, (_event, file) => {
      if (!file || ["dist", "node_modules", ".git"].some(name => file === name || file.startsWith(name + "/"))) return;
      dirty = true;
      clearTimeout(debounce); debounce = setTimeout(() => { if (autoReload) void rebuild(); else void status('paused', '自动重建已暂停；启用后将处理待更新的源码。'); }, 200);
    });
    await rebuild();
    const preferencesTimer = setInterval(async () => {
      try {
        const values = JSON.parse(await fs.readFile(path.join(home, 'preferences.json'), 'utf8'));
        const wasEnabled = autoReload; autoReload = values.developerAutoReload !== false;
        if (!wasEnabled && autoReload && dirty) void rebuild();
      } catch {}
    }, 500);
    const stop = async () => { stopped = true; watcher.close(); clearTimeout(debounce); clearInterval(preferencesTimer); await status('stopped'); process.exit(0); };
    process.on("SIGINT", stop); process.on("SIGTERM", stop);
  } else if (command === "list") native(["--list"]);
  else if (command === "rollback") native(["--rollback", positional[0] || ""]);
  else if (command === "query") native(["--query", ...positional]);
  else if (command === "search") native(["--implicit-query", positional.join(" ")]);
  else if (command === "doctor") {
    await fs.access(appBinary);
    console.log(`Host: ${appBinary}\nSDK: 0.1\nRuntime: JavaScriptCore in sandboxed XPC\nNode: ${process.version}`);
    native(["--probe"]);
  } else if (command === "inspect") {
    console.log("1. Start 'platform dev <directory> --accept-permissions'.\n2. Run the extension query in Vectracast.\n3. Safari → Develop → this Mac → Vectracast Extension.\n4. Open main.js / mapped TypeScript source and set a breakpoint.\nJSContext inspection is enabled only for development installs. This command provides the entry instructions; it does not attach a debugger automatically.");
  } else if (command === "logs") {
    const root = process.env.LAUNCHER_HOME || path.join(process.env.HOME, "Library/Application Support/Launcher");
    console.log(await fs.readFile(path.join(root, "runtime.jsonl"), "utf8").catch(() => "No logs yet."));
  } else {
    console.log("Vectracast SDK 0.1\ncreate <directory> [--youdao]\npack <directory>\nvalidate <directory>\ninstall <package> --accept-permissions\ndev <directory> --accept-permissions\nlist\nquery <extension-id> <command-id> <query>\nsearch <input>\nrollback <extension-id>\ndoctor\ninspect\nlogs");
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(e => { console.error(e.message); process.exitCode = 1; });
