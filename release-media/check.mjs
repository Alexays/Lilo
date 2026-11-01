import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const root = path.dirname(fileURLToPath(import.meta.url));
const catalog = JSON.parse(await readFile(path.join(root, "backlog.json"), "utf8"));
const publishing = process.argv.includes("--publish");
if (publishing && catalog.publication !== "approved")
  throw Error("Release blocked: backlog media has not been approved for publication.");
const markdown = await readFile(path.join(root, "../CHANGELOG.md"), "utf8");
const releases = new Map(
  [...markdown.matchAll(/^## \[([^\]]+)\][^\n]*\n([\s\S]*?)(?=^## \[|$(?![\s\S]))/gm)].map((m) => [
    m[1],
    m[2],
  ]),
);
if (
  JSON.stringify([...releases.keys()].sort()) !==
  JSON.stringify(Object.keys(catalog.releases).sort())
)
  throw Error("Every published release needs an explicit video, screenshot or none decision.");
const sha = (data) => createHash("sha256").update(data).digest("hex");
const scratch = await mkdtemp(path.join(tmpdir(), "lilo-media-check-"));
try {
  for (const [version, entry] of Object.entries(catalog.releases)) {
    if (!["none", "screenshot", "video"].includes(entry.kind) || !entry.reason?.trim())
      throw Error(`Missing editorial decision for ${version}`);
    const folder = path.join(root, "assets", version);
    if (entry.kind === "none") {
      const files = await readdir(folder).catch((e) => {
        if (e.code === "ENOENT") return [];
        throw e;
      });
      if (files.some((f) => /\.(png|mp4)$/.test(f)))
        throw Error(`Text-only release ${version} must not have media.`);
      continue;
    }
    if (!entry.notes?.length || entry.notes.some((note) => !releases.get(version).includes(note)))
      throw Error(`Media must demonstrate an exact release note: ${version}`);
    if (!entry.alt?.en || !entry.alt?.fr)
      throw Error(`Missing translated media description: ${version}`);
    const sourceBytes = await readFile(path.join(root, "public/native", version, "capture.json"));
    const source = JSON.parse(sourceBytes);
    const renderBytes = await readFile(path.join(folder, "render.json"));
    const render = JSON.parse(renderBytes);
    if (publishing && render.approved !== true)
      throw Error(`Release blocked: ${version} needs visual approval.`);
    if (
      source.release !== version ||
      source.feature !== entry.feature ||
      !source.appVersion ||
      !source.appBuild ||
      !source.productSourceCommit ||
      !source.assets.length
    )
      throw Error(`Missing native provenance: ${version}`);
    if (
      render.kind !== entry.kind ||
      render.feature !== entry.feature ||
      render.productSourceCommit !== source.productSourceCommit ||
      render.width !== 1920 ||
      render.height !== 1080
    )
      throw Error(`Stale or incorrect render: ${version}`);
    if (sha(sourceBytes) !== render.nativeReceiptSha256)
      throw Error(`Stale native capture receipt: ${version}`);
    for (const file of ["src/Root.tsx", "src/Backlog.tsx", "package-lock.json"])
      if (
        render.approved !== true &&
        sha(await readFile(path.join(root, file))) !== render.recipeHashes?.[file]
      )
        throw Error(`Stale Remotion recipe: ${version}/${file}`);
    for (const asset of source.assets) {
      if (!/^[a-z0-9-]+\.png$/.test(asset.file) || asset.width < 1 || asset.height < 1)
        throw Error(`Invalid native asset: ${version}`);
      if (
        sha(await readFile(path.join(root, "public/native", version, asset.file))) !== asset.sha256
      )
        throw Error(`Native pixels changed: ${version}/${asset.file}`);
    }
    for (const ext of ["png", ...(entry.kind === "video" ? ["mp4"] : [])]) {
      const file = `${entry.feature}.${ext}`;
      if (sha(await readFile(path.join(folder, file))) !== render.hashes[file])
        throw Error(`Rendered media changed: ${version}/${file}`);
    }
    const report = {
      release: version,
      kind: entry.kind,
      sourceHashes: true,
      renderHashes: true,
      renderSha256: sha(renderBytes),
      publication: catalog.publication,
    };
    if (publishing) {
      // Deployment images need only Node; full codec checks run in the media CI job.
      const quality = JSON.parse(await readFile(path.join(folder, "quality.json"), "utf8"));
      if (
        quality.renderSha256 !== report.renderSha256 ||
        quality.sourceHashes !== true ||
        quality.renderHashes !== true ||
        (entry.kind === "video" && quality.decode !== true)
      )
        throw Error(`Release blocked: ${version} needs a passing quality check for this render.`);
      console.log(`Approved ${version}: ${entry.kind} ${entry.feature}`);
      continue;
    }
    if (entry.kind === "video") {
      const film = path.join(folder, `${entry.feature}.mp4`);
      const { stdout } = await run("ffprobe", [
        "-v",
        "error",
        "-show_streams",
        "-show_format",
        "-of",
        "json",
        film,
      ]);
      const probe = JSON.parse(stdout),
        video = probe.streams.find((s) => s.codec_type === "video"),
        audio = probe.streams.find((s) => s.codec_type === "audio");
      if (
        video?.codec_name !== "h264" ||
        video.width !== 1920 ||
        video.height !== 1080 ||
        video.avg_frame_rate !== "60/1" ||
        audio?.codec_name !== "aac" ||
        Number(audio.sample_rate) !== 48000
      )
        throw Error(`Incorrect MP4 or sound format: ${version}`);
      if (Math.abs(Number(probe.format.duration) - render.frames / render.fps) > 0.1)
        throw Error(`Incorrect film duration: ${version}`);
      await run("ffmpeg", ["-v", "error", "-i", film, "-f", "null", "-"]);
      const { stderr: levels } = await run("ffmpeg", [
        "-hide_banner",
        "-i",
        film,
        "-vn",
        "-af",
        "volumedetect",
        "-f",
        "null",
        "-",
      ]);
      const peak = Number(/max_volume: (-?[\d.]+) dB/.exec(levels)?.[1]);
      if (!Number.isFinite(peak) || peak > -0.5 || peak < -45)
        throw Error(`Silent or clipping sound: ${version}`);
      const frame = path.join(scratch, `${version}.png`);
      await run("ffmpeg", [
        "-v",
        "error",
        "-i",
        film,
        "-vf",
        `select=eq(n\\,${render.posterFrame})`,
        "-frames:v",
        "1",
        frame,
      ]);
      const { stderr: ssim } = await run("ffmpeg", [
        "-hide_banner",
        "-i",
        frame,
        "-i",
        path.join(folder, `${entry.feature}.png`),
        "-lavfi",
        "ssim",
        "-f",
        "null",
        "-",
      ]);
      const similarity = Number(/All:([\d.]+)/.exec(ssim)?.[1]);
      if (!(similarity >= 0.98))
        throw Error(`Encoded poster differs from the sharp source frame: ${version} ${similarity}`);
      Object.assign(report, {
        decode: true,
        width: video.width,
        height: video.height,
        fps: 60,
        audioPeakDb: peak,
        posterSSIM: similarity,
      });
    }
    await writeFile(path.join(folder, "quality.json"), JSON.stringify(report, null, 2) + "\n");
    console.log(`Verified ${version}: ${entry.kind} ${entry.feature}`);
  }
} finally {
  await rm(scratch, { recursive: true, force: true });
}
console.log(
  `All ${releases.size} editorial decisions and their required media are valid. Publication: ${catalog.publication}.`,
);
