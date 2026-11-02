import { cp, mkdir, rm } from "node:fs/promises";
import path from "node:path";
import { root, json, selected, nativeSources } from "./pipeline.mjs";

const catalog = await json(path.join(root, "backlog.json"));
for (const [version, entry] of selected(catalog)) {
  if (entry.kind === "none") continue;
  const source = path.join(root, "../build/release-media/native", version);
  const native = await nativeSources(version, entry, source);
  const target = path.join(root, "public/native", version);
  await rm(target, { recursive: true, force: true });
  for (const { path: file } of [...native.receipts, ...native.assets]) {
    const from = path.resolve(root, file);
    const to = path.join(target, path.relative(source, from));
    await mkdir(path.dirname(to), { recursive: true });
    await cp(from, to);
  }
  console.log(`Imported native sources for ${version}: ${entry.feature}`);
}
