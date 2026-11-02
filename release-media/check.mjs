import { execFile } from "node:child_process";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { root, sha, json, selected, nativeSources, recipeHashes, same } from "./pipeline.mjs";

const run = promisify(execFile);
const publishing = process.argv.includes("--publish");
const catalog = await json(path.join(root, "backlog.json"));
if (catalog.publication !== "quality-gated")
  throw Error("Release blocked: media publication is disabled.");
const markdown = await readFile(path.join(root, "../CHANGELOG.md"), "utf8");
const releases = new Map(
  [...markdown.matchAll(/^## \[([^\]]+)\][^\n]*\n([\s\S]*?)(?=^## \[|$(?![\s\S]))/gm)].map(
    (match) => [match[1], match[2]],
  ),
);
if (!same([...releases.keys()].sort(), Object.keys(catalog.releases).sort()))
  throw Error("Every published release needs a video, screenshot or none decision.");
const passesMotion = (m, frames) =>
  m?.measuredFrames === frames - 1 &&
  Number.isFinite(m.movingFrameRatio) &&
  m.movingFrameRatio >= 0.2 &&
  m.movingFrameRatio <= 1 &&
  Number.isFinite(m.longestStillSeconds) &&
  m.longestStillSeconds <= 3 &&
  Number.isFinite(m.largestLumaChange) &&
  m.largestLumaChange <= 45;
const passesQuality = (q, render, hash) =>
  q?.passed === true &&
  q.renderSha256 === hash &&
  q.sourceHashes === true &&
  q.renderHashes === true &&
  q.cutoutsVerified === true &&
  q.strictCompositionCheck === true &&
  (render.kind !== "video" ||
    (q.decode === true &&
      passesMotion(q.motion, render.frames) &&
      q.posterSSIM >= 0.98 &&
      q.audio?.integratedLoudnessLUFS >= -19 &&
      q.audio?.integratedLoudnessLUFS <= -13 &&
      q.audio?.truePeakDbFS <= -0.7));

async function verifyCutouts(render, project) {
  const { default: sharp } = await import("sharp");
  const results = [];
  for (const cut of render.cutouts) {
    const original = sharp(path.join(root, cut.source));
    if (cut.crop) {
      const [left, top, width, height] = cut.crop;
      original.extract({ left, top, width, height });
    }
    const before = await original.ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    const target = path.join(project, "assets/native", cut.file);
    const after = await sharp(target).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    if (
      after.info.width !== before.info.width ||
      after.info.height !== before.info.height ||
      after.info.channels !== 4
    )
      throw Error(`Cutout dimensions changed: ${cut.file}`);
    const rgb = Buffer.allocUnsafe(after.info.width * after.info.height * 3);
    const alpha = Buffer.allocUnsafe(after.info.width * after.info.height);
    let clear = 0,
      opaque = 0;
    for (let pixel = 0; pixel < alpha.length; pixel++) {
      const i = pixel * 4;
      for (let c = 0; c < 3; c++) {
        if (before.data[i + c] !== after.data[i + c])
          throw Error(`Native RGB changed: ${cut.file}`);
        rgb[pixel * 3 + c] = after.data[i + c];
      }
      const a = after.data[i + 3];
      if (a > before.data[i + 3]) throw Error(`Native opacity increased: ${cut.file}`);
      alpha[pixel] = a;
      clear += Number(a === 0);
      opaque += Number(a === 255);
    }
    if (
      !clear ||
      !opaque ||
      sha(rgb) !== cut.beforeRgbSha256 ||
      sha(rgb) !== cut.afterRgbSha256 ||
      sha(alpha) !== cut.afterAlphaSha256 ||
      clear !== cut.transparentPixels ||
      opaque !== cut.opaquePixels
    )
      throw Error(`Invalid alpha receipt: ${cut.file}`);
    results.push({ file: cut.file, rgbPreserved: true, transparentPixels: clear });
  }
  return results;
}

const scratch = await mkdtemp(path.join(tmpdir(), "lilo-media-qa-"));
try {
  for (const [version, entry] of selected(catalog)) {
    if (!["none", "screenshot", "video"].includes(entry.kind) || !entry.reason?.trim())
      throw Error(`Missing editorial decision: ${version}`);
    const folder = path.join(root, "assets", version);
    if (entry.kind === "none") {
      const files = await readdir(folder).catch((error) => {
        if (error.code === "ENOENT") return [];
        throw error;
      });
      if (files.some((file) => /\.(png|mp4)$/.test(file)))
        throw Error(`Text-only release has media: ${version}`);
      continue;
    }
    if (
      !entry.alt?.en ||
      !entry.alt?.fr ||
      !entry.notes?.length ||
      entry.notes.some((note) => !releases.get(version)?.includes(note))
    )
      throw Error(`Media must describe exact release notes in both locales: ${version}`);
    const native = await nativeSources(version, entry);
    const bytes = await readFile(path.join(folder, "render.json")),
      render = JSON.parse(bytes);
    if (
      render.schemaVersion !== 2 ||
      render.engine !== "hyperframes" ||
      render.release !== version ||
      render.kind !== entry.kind ||
      render.feature !== entry.feature ||
      render.width !== 1920 ||
      render.height !== 1080 ||
      render.fps !== 60 ||
      render.publication !== "quality-gated" ||
      render.strictCompositionCheck !== true
    )
      throw Error(`Stale HyperFrames render: ${version}`);
    if (!same(render.nativeReceipts, native.receipts))
      throw Error(`Native receipt changed: ${version}`);
    if (!same(render.recipeHashes, await recipeHashes(entry)))
      throw Error(`HyperFrames recipe changed: ${version}`);
    if (
      publishing &&
      process.env.LILO_RELEASE_MEDIA_VERSION &&
      process.env.GITHUB_REF_TYPE === "tag" &&
      process.env.GITHUB_SHA &&
      render.nativeReceipts.some(
        (receipt) => receipt.productSourceCommit !== process.env.GITHUB_SHA,
      )
    )
      throw Error(`Release blocked: native capture is not from this tag: ${version}`);
    const expectedHashes = [
      `${entry.feature}.png`,
      ...(entry.kind === "video" ? [`${entry.feature}.mp4`] : []),
    ];
    if (
      !same(Object.keys(render.hashes ?? {}).sort(), expectedHashes.sort()) ||
      Object.values(render.hashes).some((hash) => !/^[a-f0-9]{64}$/.test(hash))
    )
      throw Error(`Missing or invalid rendered hashes: ${version}`);
    if (
      publishing &&
      process.env.LILO_RELEASE_MEDIA_VERSION &&
      process.env.GITHUB_REF_TYPE === "tag" &&
      render.nativeReceipts.some((receipt) => receipt.appVersion !== version)
    )
      throw Error(`Release blocked: captured app version does not match the tag: ${version}`);
    for (const [file, hash] of Object.entries(render.hashes)) {
      if (
        !/^[a-z0-9-]+\.(png|mp4)$/.test(file) ||
        sha(await readFile(path.join(folder, file))) !== hash
      )
        throw Error(`Rendered media changed: ${version}/${file}`);
    }
    if (entry.kind === "video") {
      const license = await json(path.join(root, "public/audio/music.license.json"));
      if (
        license.license !== "CC0-1.0" ||
        license.attributionRequired !== false ||
        !same(render.music, license)
      )
        throw Error("Release blocked: soundtrack must not require attribution");
    }
    const hash = sha(bytes);
    if (publishing) {
      const q = await json(path.join(folder, "quality.json"));
      if (!passesQuality(q, render, hash))
        throw Error(
          `Release blocked: ${version} needs a passing quality check for these exact bytes.`,
        );
      console.log(`Quality-gated ${version}: ${entry.kind} ${entry.feature}`);
      continue;
    }
    await rm(path.join(folder, "quality.json"), { force: true });
    const project = path.join(root, "../build/release-media/projects", version);
    const report = {
      release: version,
      kind: entry.kind,
      passed: false,
      renderSha256: hash,
      sourceHashes: true,
      renderHashes: true,
      strictCompositionCheck: true,
      cutoutsVerified: false,
    };
    const composition = await json(path.join(project, "check.json"));
    if (
      composition.ok !== true ||
      composition.strict !== true ||
      composition.browserSkipped === true
    )
      throw Error(`HyperFrames runtime check missing: ${version}`);
    report.cutouts = await verifyCutouts(render, project);
    report.cutoutsVerified = true;
    const { default: sharp } = await import("sharp");
    const poster = path.join(folder, `${entry.feature}.png`);
    const picture = await sharp(poster).metadata();
    if (picture.format !== "png" || picture.width !== 1920 || picture.height !== 1080)
      throw Error(`Invalid lossless poster: ${version}`);
    if (entry.kind === "video") {
      const film = path.join(folder, `${entry.feature}.mp4`);
      const probe = JSON.parse(
        (
          await run("ffprobe", [
            "-v",
            "error",
            "-count_frames",
            "-show_streams",
            "-show_format",
            "-of",
            "json",
            film,
          ])
        ).stdout,
      );
      const video = probe.streams.find((s) => s.codec_type === "video"),
        audio = probe.streams.find((s) => s.codec_type === "audio");
      if (
        video?.codec_name !== "h264" ||
        video.width !== 1920 ||
        video.height !== 1080 ||
        video.pix_fmt !== "yuv420p" ||
        video.avg_frame_rate !== "60/1" ||
        Number(video.nb_read_frames) !== render.frames ||
        audio?.codec_name !== "aac" ||
        Number(audio.sample_rate) !== 48000 ||
        audio.channels !== 2 ||
        Math.abs(Number(probe.format.duration) - render.frames / 60) > 0.05
      )
        throw Error(`Incorrect 1080p60 H.264/AAC output: ${version}`);
      const { stderr: analysis } = await run(
        "ffmpeg",
        [
          "-hide_banner",
          "-xerror",
          "-i",
          film,
          "-vf",
          "scale=240:135,tblend=all_mode=difference,signalstats,metadata=print:key=lavfi.signalstats.YAVG",
          "-af",
          "ebur128=peak=true",
          "-f",
          "null",
          "-",
        ],
        { maxBuffer: 12 * 1024 * 1024 },
      );
      const tail = analysis.slice(analysis.lastIndexOf("Summary:"));
      const loudness = Number(/I:\s*(-?[\d.]+) LUFS/.exec(tail)?.[1]),
        peak = Number(/Peak:\s*(-?[\d.]+) dBFS/.exec(tail)?.[1]);
      if (
        !Number.isFinite(loudness) ||
        loudness < -19 ||
        loudness > -13 ||
        !Number.isFinite(peak) ||
        peak > -0.7
      )
        throw Error(`Silent or clipping soundtrack: ${version}`);
      const deltas = [...analysis.matchAll(/lavfi.signalstats.YAVG=([\d.e+-]+)/g)].map((m) =>
        Number(m[1]),
      );
      let runStill = 0,
        longest = 0;
      for (const value of deltas) {
        runStill = value < 0.04 ? runStill + 1 : 0;
        longest = Math.max(longest, runStill);
      }
      const motion = {
        measuredFrames: deltas.length,
        movingFrameRatio: deltas.filter((d) => d >= 0.04).length / deltas.length,
        longestStillSeconds: longest / 60,
        largestLumaChange: Math.max(...deltas),
      };
      if (!passesMotion(motion, render.frames))
        throw Error(`Motion quality failed for ${version}: ${JSON.stringify(motion)}`);
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
      const { stderr: result } = await run("ffmpeg", [
        "-hide_banner",
        "-i",
        frame,
        "-i",
        poster,
        "-lavfi",
        "ssim",
        "-f",
        "null",
        "-",
      ]);
      const ssim = Number(/All:([\d.]+)/.exec(result)?.[1]);
      if (!(ssim >= 0.98)) throw Error(`Encoded UI is too blurry: ${version}`);
      Object.assign(report, {
        decode: true,
        fps: 60,
        frames: render.frames,
        audio: { integratedLoudnessLUFS: loudness, truePeakDbFS: peak },
        motion,
        posterSSIM: ssim,
      });
    }
    report.passed = true;
    await writeFile(path.join(folder, "quality.json"), JSON.stringify(report, null, 2) + "\n");
    console.log(`Verified HyperFrames ${version}: ${entry.kind} ${entry.feature}`);
  }
} finally {
  await rm(scratch, { recursive: true, force: true });
}
