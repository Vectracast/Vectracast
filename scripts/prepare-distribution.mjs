import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(
  await fs.readFile(path.join(root, "distribution.json"), "utf8"),
);
config.appRepository =
  process.env.VECTRACAST_APP_REPOSITORY || config.appRepository;
const officialPluginRepository = "hi-jian/Vectracast-Plugins";
if (config.pluginRepository !== officialPluginRepository ||
    (process.env.VECTRACAST_PLUGIN_REPOSITORY && process.env.VECTRACAST_PLUGIN_REPOSITORY !== officialPluginRepository))
  throw Error("Plugin repository is fixed to " + officialPluginRepository);
for (const key of ["appRepository", "pluginRepository"]) {
  if (
    typeof config[key] !== "string" ||
    (config[key] &&
      !/^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/.test(
        config[key],
      ))
  )
    throw Error("Invalid " + key);
}
if (process.env.CI && (!config.appRepository || !config.pluginRepository))
  throw Error("Configure both public repositories before publishing.");
await fs.writeFile(process.argv[2], JSON.stringify(config, null, 2) + "\n");
