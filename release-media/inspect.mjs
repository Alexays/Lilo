import { execFile } from "node:child_process";
import { mkdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const root = path.dirname(fileURLToPath(import.meta.url));
const catalog = JSON.parse(await readFile(path.join(root, "backlog.json"), "utf8"));
const selected = process.env.LILO_RELEASE_MEDIA_VERSION;
if (selected && !Object.hasOwn(catalog.releases, selected))
  throw Error("Unknown release media version");
for (const [version, entry] of Object.entries(catalog.releases)) {
  if (entry.kind !== "video" || (selected && selected !== version)) continue;
  const folder = path.join(root, "assets", version);
  const render = JSON.parse(await readFile(path.join(folder, "render.json"), "utf8"));
  const output = path.join(root, "../build/release-media/inspection", version);
  await mkdir(output, { recursive: true });
  await run("ffmpeg", [
    "-v",
    "error",
    "-y",
    "-i",
    path.join(folder, `${entry.feature}.mp4`),
    "-vf",
    `fps=${12 / (render.frames / render.fps)},scale=342:192,tile=4x3`,
    "-frames:v",
    "1",
    path.join(output, "compact-frames.png"),
  ]);
  console.log(`Inspect ${version}: ${output}/compact-frames.png`);
}
