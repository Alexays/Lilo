import { cp, mkdir, readFile, readdir, rm } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const catalog = JSON.parse(await readFile(path.join(root, "backlog.json"), "utf8"));
const pkg = JSON.parse(await readFile(path.join(root, "../lilo-ui/package.json"), "utf8"));
const version = process.env.LILO_RELEASE_MEDIA_PREVIEW_VERSION || pkg.version;
const entry = catalog.releases[version];
const capturing = process.env.LILO_RELEASE_MEDIA_CAPTURE_ONLY === "1";
const target = path.join(root, "../lilo-ui/public/release-media");
await mkdir(target, { recursive: true });
for (const name of await readdir(target))
  if (name !== ".gitkeep") await rm(path.join(target, name), { recursive: true, force: true });
if (!capturing && entry && entry.kind !== "none") {
  await mkdir(path.join(target, version), { recursive: true });
  for (const ext of ["png", ...(entry.kind === "video" ? ["mp4"] : [])]) {
    const file = `${entry.feature}.${ext}`;
    await cp(path.join(root, "assets", version, file), path.join(target, version, file), {
      errorOnExist: true,
    });
  }
}
console.log(
  capturing
    ? "Native release media: omitted from capture host"
    : `Native release media: ${version} ${entry?.kind ?? "none"}`,
);
