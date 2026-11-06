import { execFile } from "node:child_process";
import { copyFile, mkdir, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { composition } from "./templates.mjs";

const run = promisify(execFile);
const root = path.dirname(fileURLToPath(import.meta.url));
const cli = path.join(root, "node_modules/hyperframes/bin/hyperframes.mjs");
const env = { ...process.env, DO_NOT_TRACK: "1" };
const MAX_FILM_BYTES = 12 * 1024 * 1024;

const hyperframes = (...args) =>
  run(process.execPath, [cli, ...args], { env, maxBuffer: 1 << 26 }).catch(() => {
    throw Error(`hyperframes ${args[0]} failed. Run it on ${args[1]} to see why.`);
  });

/** Plays the encoded film to its end: a file that merely exists is not a film. */
async function verifyFilm(file) {
  const { stdout } = await run("ffprobe", [
    ...["-v", "error", "-show_streams", "-of", "json", file],
  ]);
  const { streams } = JSON.parse(stdout);
  const video = streams.find((stream) => stream.codec_type === "video");
  if (video?.codec_name !== "h264" || video.width !== 1920 || video.height !== 1080)
    throw Error(`Not a 1080p H.264 film: ${file}`);
  if (video.pix_fmt !== "yuv420p") throw Error(`A browser cannot play ${video.pix_fmt}: ${file}`);
  if ((await stat(file)).size > MAX_FILM_BYTES) throw Error(`Too heavy for the changelog: ${file}`);
  await run("ffmpeg", ["-v", "error", "-xerror", "-i", file, "-f", "null", "-"]);
}

/** Renders one highlight's shots to `assets/<version>/<id>.{mp4,png}` and returns its media kind. */
export async function renderHighlight({ version, id, template, directory, shots }) {
  const { html, poster } = composition({ template, shots });
  const project = path.join(root, "../build/release-media/projects", version, id);
  await rm(project, { recursive: true, force: true });
  await mkdir(path.join(project, "assets/shots"), { recursive: true });
  await writeFile(path.join(project, "index.html"), html);
  await copyFile(
    path.join(root, "node_modules/gsap/dist/gsap.min.js"),
    path.join(project, "assets/gsap.min.js"),
  );
  for (const { file } of shots)
    await copyFile(path.join(directory, file), path.join(project, "assets/shots", file));
  await hyperframes("check", project, "--strict");

  const output = path.join(root, "assets", version);
  await mkdir(output, { recursive: true });
  const stills = path.join(project, "stills");
  await hyperframes(
    "snapshot", project, "--at", String(poster), "--no-end", "--output", stills,
    "--zoom", "0,0,1920,1080", "--zoom-scale", template === "image" ? "2" : "1",
  );
  await copyFile(path.join(stills, `frame-00-at-${poster}s.png`), path.join(output, `${id}.png`));
  if (template === "image") return "image";

  const film = path.join(output, `${id}.mp4`);
  await hyperframes(
    "render", project, "--output", film, "--fps", "30", "--crf", "20", "--strict",
    "--page-motion-blur", "off",
  );
  await verifyFilm(film);
  return "loop";
}

/** Downloads the pinned browser the first render needs. */
export const prepare = () => hyperframes("browser", "ensure");
