import fs from "node:fs/promises";
const repo = process.env.GITHUB_REPOSITORY;
if (!/^[A-Za-z0-9-]+\/[A-Za-z0-9_.-]+$/.test(repo || ""))
  throw Error("Invalid repository");
const response = await fetch(
  `https://api.github.com/repos/${repo}/releases/latest`,
  {
    headers: {
      Accept: "application/vnd.github+json",
      ...(process.env.GH_TOKEN
        ? { Authorization: `Bearer ${process.env.GH_TOKEN}` }
        : {}),
    },
    signal: AbortSignal.timeout(30000),
  },
);
let index = { schemaVersion: 1, plugins: [] };
if (response.status !== 404) {
  if (!response.ok)
    throw Error("Cannot check previous release: HTTP " + response.status);
  const release = await response.json();
  const asset = release.assets.find((a) => a.name === "index.json");
  if (!asset) throw Error("Previous release is missing index.json");
  const url = new URL(asset.browser_download_url);
  if (
    url.origin !== "https://github.com" ||
    !url.pathname.startsWith(`/${repo}/releases/download/`)
  )
    throw Error("Unexpected index URL");
  const file = await fetch(url, { signal: AbortSignal.timeout(30000) });
  if (!file.ok) throw Error("Cannot download previous catalog");
  const text = await file.text();
  if (Buffer.byteLength(text) > 2_000_000) throw Error("Catalog too large");
  index = JSON.parse(text);
}
await fs.writeFile(process.argv[2], JSON.stringify(index));
