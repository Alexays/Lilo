import { cp, mkdir, readFile, rm } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));

/** The installed release's highlight media, the only media the app bundle carries. */
export function stagedFiles(version, registry) {
  return (registry[version]?.highlights ?? [])
    .filter((highlight) => highlight.media)
    .flatMap(({ id, media }) => [`${id}.png`, ...(media === "image" ? [] : [`${id}.mp4`])]);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const ui = path.join(root, "../lilo-ui");
  const { version } = JSON.parse(await readFile(path.join(ui, "package.json"), "utf8"));
  const registry = JSON.parse(
    await readFile(path.join(ui, "src/components/whatsnew/releaseHighlights.json"), "utf8"),
  );
  const target = path.join(ui, "public/release-media");
  await rm(path.join(target, version), { recursive: true, force: true });
  const files = stagedFiles(version, registry);
  for (const file of files) {
    await mkdir(path.join(target, version), { recursive: true });
    await cp(path.join(root, "assets", version, file), path.join(target, version, file));
  }
  console.log(`Native release media: ${version}, ${files.length} file(s)`);
}
