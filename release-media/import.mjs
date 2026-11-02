import { cp, rm } from "node:fs/promises";
import path from "node:path";
import { root, json, selected, nativeSources } from "./pipeline.mjs";

const catalog = await json(path.join(root, "backlog.json"));
for (const [version, entry] of selected(catalog)) {
  if (entry.kind === "none") continue;
  const source = path.join(root, "../build/release-media/native", version);
  await nativeSources(version, entry, source);
  const target = path.join(root, "public/native", version);
  await rm(target, { recursive: true, force: true });
  await cp(source, target, { recursive: true });
  console.log(`Imported native sources for ${version}: ${entry.feature}`);
}
