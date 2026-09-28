import fs from "node:fs/promises";
import path from "node:path";
import { pack, projectRoot } from "../packages/cli/bin/platform.mjs";
const { output } = await pack(
  path.join(projectRoot, "extensions/plugin-store"),
  { release: true },
);
await fs.copyFile(
  output,
  path.join(
    projectRoot,
    "build/Vectracast.app/Contents/Resources/PluginStore.launcher-extension",
  ),
);
