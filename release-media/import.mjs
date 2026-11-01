import { createHash } from "node:crypto";
import { copyFile, mkdir, readFile } from "node:fs/promises";
import path from "node:path";

const root = path.dirname(new URL(import.meta.url).pathname);
const catalog = JSON.parse(await readFile(path.join(root, "backlog.json"), "utf8"));
if (
  process.env.LILO_RELEASE_MEDIA_VERSION &&
  !Object.hasOwn(catalog.releases, process.env.LILO_RELEASE_MEDIA_VERSION)
)
  throw Error("Unknown release media version");
for (const [version, entry] of Object.entries(catalog.releases)) {
  if (
    entry.kind === "none" ||
    (process.env.LILO_RELEASE_MEDIA_VERSION && version !== process.env.LILO_RELEASE_MEDIA_VERSION)
  )
    continue;
  const previous = JSON.parse(
    await readFile(path.join(root, "assets", version, "render.json"), "utf8").catch((error) => {
      if (error.code === "ENOENT") return "null";
      throw error;
    }),
  );
  if (previous?.approved === true) {
    console.log(`Preserved approved ${version} native sources`);
    continue;
  }
  const source = path.join(root, "../build/release-media/native", version);
  const receipt = JSON.parse(await readFile(path.join(source, "capture.json"), "utf8"));
  if (
    receipt.release !== version ||
    receipt.feature !== entry.feature ||
    !receipt.appVersion ||
    !receipt.appBuild ||
    !receipt.productSourceCommit
  )
    throw Error(`Invalid native receipt for ${version}`);
  const target = path.join(root, "public/native", version);
  await mkdir(target, { recursive: true });
  for (const asset of receipt.assets) {
    if (!/^[a-z0-9-]+\.png$/.test(asset.file)) throw Error("Unsafe native filename");
    const filename = path.join(source, asset.file);
    const digest = createHash("sha256")
      .update(await readFile(filename))
      .digest("hex");
    if (digest !== asset.sha256)
      throw Error(`Native source hash mismatch for ${version}/${asset.file}`);
    await copyFile(filename, path.join(target, asset.file));
  }
  await copyFile(path.join(source, "capture.json"), path.join(target, "capture.json"));
  console.log(
    `Imported actual native ${receipt.appVersion} (${receipt.appBuild}) sources for ${version}: ${entry.feature}`,
  );
}
