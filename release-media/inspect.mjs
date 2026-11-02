import { execFile } from "node:child_process";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { root, json, selected } from "./pipeline.mjs";
import { promisify } from "node:util";

const run = promisify(execFile);
const catalog = await json(path.join(root, "backlog.json"));
for (const [version, entry] of selected(catalog)) {
  if (entry.kind !== "video") continue;
  const folder = path.join(root, "assets", version);
  const render = await json(path.join(folder, "render.json"));
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
