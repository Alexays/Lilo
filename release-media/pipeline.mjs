import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const root = path.dirname(fileURLToPath(import.meta.url));
export const sha = (data) => createHash("sha256").update(data).digest("hex");
export const json = async (file) => JSON.parse(await readFile(file, "utf8"));
export const fixtures = {
  browser: "0.1.0",
  "pinned-tabs": "0.1.3",
  "tab-edges": "0.2.0",
  settings: "0.3.0",
  updates: "0.4.0",
  unread: "0.6.0",
  calls: "0.7.0",
  "tab-share": "0.8.0",
  history: "0.9.0",
  archive: "0.10.0",
  spaces: "0.11.0",
  "site-colors": "0.12.0",
  seasons: "0.13.0",
  drop: "0.14.0",
};
export async function filesBelow(directory) {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) result.push(...(await filesBelow(file)));
    else result.push(file);
  }
  return result.sort();
}
export function recipeDirectory(entry) {
  const version = entry.recipeVersion ?? fixtures[entry.feature];
  if (
    !version ||
    version !== fixtures[entry.feature] ||
    (entry.variant && (entry.variant !== "share" || entry.feature !== "tab-share"))
  )
    throw Error(`No genuine capture capability for ${entry.feature}`);
  return path.join(
    root,
    "hyperframes",
    version === "0.8.0" && entry.variant !== "share" ? version : `archive/${version}`,
  );
}
export async function recipeHashes(entry) {
  const files = [
    "render.mjs",
    "pipeline.mjs",
    "png-cutouts.mjs",
    "package-lock.json",
    "public/audio/music.ogg",
    "public/audio/music.license.json",
    "public/audio/music.LICENSE.txt",
    "public/audio/mouse-click.wav",
    "public/audio/switch.wav",
    "hyperframes/assets/inter.woff2",
    "hyperframes/assets/logo.svg",
  ].map((file) => path.join(root, file));
  if (entry.kind === "video") {
    files.push(...(await filesBelow(recipeDirectory(entry))));
    if ((entry.recipeVersion ?? fixtures[entry.feature]) !== "0.8.0")
      files.push(
        path.join(root, "hyperframes/archive/shared.css"),
        path.join(root, "hyperframes/archive/shared.js"),
      );
  }
  return Object.fromEntries(
    await Promise.all(
      files.map(async (file) => [path.relative(root, file), sha(await readFile(file))]),
    ),
  );
}
export async function nativeSources(version, entry) {
  const folder = path.join(root, "public/native", version);
  const receipts = [];
  const assets = [];
  for (const file of (await filesBelow(folder)).filter(
    (file) => path.basename(file) === "capture.json",
  )) {
    const bytes = await readFile(file),
      receipt = JSON.parse(bytes);
    if (
      !receipt.appVersion ||
      !receipt.appBuild ||
      !receipt.productSourceCommit ||
      !receipt.assets?.length
    )
      throw Error(`Incomplete native receipt: ${file}`);
    if (
      file === path.join(folder, "capture.json") &&
      (receipt.release !== version || receipt.feature !== entry.feature)
    )
      throw Error(`Incorrect native capture for ${version}`);
    for (const asset of receipt.assets) {
      if (!/^[a-z0-9-]+\.png$/.test(asset.file) || !(asset.width > 0) || !(asset.height > 0))
        throw Error(`Invalid native asset: ${version}/${asset.file}`);
      const filename = path.join(path.dirname(file), asset.file);
      if (sha(await readFile(filename)) !== asset.sha256)
        throw Error(`Native pixels changed: ${filename}`);
      assets.push({ ...asset, path: path.relative(root, filename) });
    }
    receipts.push({
      path: path.relative(root, file),
      sha256: sha(bytes),
      appVersion: receipt.appVersion,
      appBuild: receipt.appBuild,
      productSourceCommit: receipt.productSourceCommit,
    });
  }
  if (!receipts.some((receipt) => receipt.path === `public/native/${version}/capture.json`))
    throw Error(`Missing genuine native capture: ${version}`);
  return { receipts, assets };
}
export const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
export function selected(catalog) {
  const version = process.env.LILO_RELEASE_MEDIA_VERSION;
  if (version && !catalog.releases[version])
    throw Error(`Unknown release media version: ${version}`);
  return Object.entries(catalog.releases).filter(([key]) => !version || key === version);
}
