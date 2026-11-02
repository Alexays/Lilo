import { createHash } from "node:crypto";
import { cp, mkdir, readFile, rm } from "node:fs/promises";
import { filesBelow } from "./pipeline.mjs";
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
  for (const receiptFile of (await filesBelow(source)).filter(
    (file) => path.basename(file) === "capture.json",
  )) {
    const captured = JSON.parse(await readFile(receiptFile, "utf8"));
    if (!captured.appVersion || !captured.productSourceCommit)
      throw Error("Incomplete native capture receipt");
    for (const asset of captured.assets) {
      if (!/^[a-z0-9-]+\.png$/.test(asset.file)) throw Error("Unsafe native filename");
      const filename = path.join(path.dirname(receiptFile), asset.file);
      const digest = createHash("sha256")
        .update(await readFile(filename))
        .digest("hex");
      if (digest !== asset.sha256)
        throw Error(`Native source hash mismatch for ${version}/${asset.file}`);
    }
  }
  await rm(target, { recursive: true, force: true });
  await cp(source, target, { recursive: true });
  console.log(
    `Imported actual native ${receipt.appVersion} (${receipt.appBuild}) sources for ${version}: ${entry.feature}`,
  );
}
