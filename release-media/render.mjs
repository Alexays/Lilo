import { createRenderJob, executeRenderJob, resolveConfig } from "@hyperframes/producer";
import { execFile } from "node:child_process";
import { cp, copyFile, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { isolateNativePng } from "./png-cutouts.mjs";
import {
  root,
  sha,
  json,
  selected,
  nativeSources,
  resolveRecipe,
  recipeHashes,
  same,
  filesBelow,
  sharedTabShareScenes,
} from "./pipeline.mjs";

const run = promisify(execFile);
const catalog = await json(path.join(root, "backlog.json"));
const entries = selected(catalog);
const cli = path.join(root, "node_modules/hyperframes/bin/hyperframes.mjs");
const env = { ...process.env, DO_NOT_TRACK: "1", PRODUCER_BROWSER_GPU_MODE: "software" };
await run(process.execPath, [cli, "browser", "ensure"], { env });
const browserPath = (await run(process.execPath, [cli, "browser", "path"], { env })).stdout.trim();
env.HYPERFRAMES_BROWSER_PATH = browserPath;
if (entries.some(([, entry]) => entry.kind === "video")) {
  const musicLicense = await json(path.join(root, "public/audio/music.license.json"));
  if (
    musicLicense.license !== "CC0-1.0" ||
    musicLicense.attributionRequired !== false ||
    sha(await readFile(path.join(root, "public/audio/music.ogg"))) !== musicLicense.sha256 ||
    sha(await readFile(path.join(root, "public/audio/music.LICENSE.txt"))) !==
      musicLicense.licenseSha256
  )
    throw Error("A verified CC0 soundtrack without an attribution requirement is required");
}

async function cliRun(args, project, log) {
  try {
    const { stdout, stderr } = await run(process.execPath, [cli, ...args], {
      cwd: project,
      env,
      maxBuffer: 32 * 1024 * 1024,
    });
    if (log) await writeFile(log, stdout);
    if (stderr) await writeFile(`${log}.log`, stderr);
    return stdout;
  } catch (error) {
    if (log) await writeFile(log, error.stdout ?? "");
    if (log) await writeFile(`${log}.log`, error.stderr ?? error.message);
    throw Error(`HyperFrames ${args[0]} failed: ${log}`);
  }
}

function stillHtml(feature) {
  const data = {
    browser: ["A place to begin.", "browser", 1664],
    settings: ["Settings, in one place.", "settings-window", 1664],
    updates: ["Ready when you are.", "updates", 1560],
    unread: ["Unread, at a glance.", "unread", 1460],
    "site-colors": ["A little more colour.", "site-colors", 1664],
    seasons: ["Dressed for the occasion.", "halloween", 480],
  }[feature];
  if (!data) throw Error(`Missing screenshot composition: ${feature}`);
  const [title, file, width] = data;
  const pictures = feature === "seasons" ? ["halloween", "christmas", "easter"] : [file];
  return `<!doctype html><html lang="en"><meta charset="utf-8"><style>@font-face{font-family:LiloInter;src:url('assets/fonts/inter.woff2')}html,body{margin:0;width:1920px;height:1080px;overflow:hidden;background:#eeedf2;font-family:LiloInter,sans-serif;color:#26232f}#main{position:relative;width:1920px;height:1080px}h1{position:absolute;left:158px;top:55px;margin:0;font-size:112px;line-height:1.1;letter-spacing:-5px}.pictures{position:absolute;left:128px;right:128px;top:240px;bottom:50px;display:flex;gap:40px;align-items:center;justify-content:center}.pictures img{display:block;max-height:790px;width:${width}px;object-fit:contain;max-width:100%}</style><main id="main" data-composition-id="main" data-width="1920" data-height="1080" data-duration="1" data-no-timeline="true"><h1>${title}</h1><div class="pictures">${pictures.map((name) => `<img id="${name}" src="assets/native/${name}.png" alt="Native Lilo ${feature}"/>`).join("")}</div></main></html>`;
}

for (const [version, entry] of entries) {
  if (entry.kind === "none") continue;
  const native = await nativeSources(version, entry);
  const recipe = resolveRecipe(entry);
  const recipes = await recipeHashes(entry, recipe);
  const folder = path.join(root, "assets", version);
  const project = path.join(root, "../build/release-media/projects", version);
  const staged = await json(path.join(project, "check.json")).catch(() => null);
  const previous = await json(path.join(folder, "render.json")).catch(() => null);
  if (
    previous?.schemaVersion === 3 &&
    previous.engine === "hyperframes" &&
    staged?.ok === true &&
    staged.strict === true &&
    same(previous.recipe, recipe) &&
    same(previous.recipeHashes, recipes) &&
    same(previous.nativeReceipts, native.receipts)
  ) {
    const valid = await Promise.all(
      Object.entries(previous.hashes).map(
        async ([file, hash]) => sha(await readFile(path.join(folder, file))) === hash,
      ),
    ).catch(() => [false]);
    if (valid.every(Boolean)) {
      console.log(`Reused unchanged HyperFrames media: ${version}`);
      continue;
    }
  }
  await mkdir(folder, { recursive: true });
  await rm(path.join(folder, "quality.json"), { force: true });
  await rm(path.join(folder, "render.json"), { force: true });
  await rm(project, { recursive: true, force: true });
  await mkdir(project, { recursive: true });
  const metadata =
    entry.kind === "video"
      ? await json(path.join(root, recipe.directory, "metadata.json"))
      : { duration: 1, posterFrame: 0 };
  const duration = metadata.duration;
  if (!(duration > 0 && duration <= 40)) throw Error(`Invalid storyboard duration: ${version}`);
  if (entry.kind === "video") {
    await cp(path.join(root, recipe.directory), project, { recursive: true });
    if (recipe.fixture === "0.8.0" && recipe.variant === "share")
      for (const scene of sharedTabShareScenes)
        await copyFile(
          path.join(root, "hyperframes/0.8.0/compositions", `${scene}.html`),
          path.join(project, "compositions", `${scene}.html`),
        );
    if (recipe.fixture !== "0.8.0") {
      for (const file of ["shared.css", "shared.js"])
        await copyFile(path.join(root, "hyperframes/archive", file), path.join(project, file));
      const index = await readFile(path.join(project, "index.html"), "utf8");
      const endingDuration = index.match(/id="ending"[^>]*data-duration="([^"]+)"/)?.[1];
      if (!endingDuration || !metadata.caption) throw Error(`Missing ending: ${version}`);
      const ending = (await readFile(path.join(root, "hyperframes/archive/ending.html"), "utf8"))
        .replaceAll("{{VERSION}}", version)
        .replaceAll(
          "{{CAPTION}}",
          metadata.caption.replaceAll("&", "&amp;").replaceAll("<", "&lt;"),
        )
        .replaceAll("{{DURATION}}", endingDuration);
      await writeFile(path.join(project, "compositions/ending.html"), ending);
    }
    if (recipe.fixture !== version)
      for (const file of (await filesBelow(project)).filter((file) => file.endsWith(".html")))
        await writeFile(file, (await readFile(file, "utf8")).replaceAll(recipe.fixture, version));
  } else await writeFile(path.join(project, "index.html"), stillHtml(entry.feature));
  await cp(path.join(root, "public/native", version), path.join(project, "assets/native"), {
    recursive: true,
  });
  for (const dir of ["fonts", ...(entry.kind === "video" ? ["audio", "vendor"] : [])])
    await mkdir(path.join(project, "assets", dir), { recursive: true });
  await copyFile(
    path.join(root, "hyperframes/assets/inter.woff2"),
    path.join(project, "assets/fonts/inter.woff2"),
  );
  if (entry.kind === "video") {
    await copyFile(
      path.join(root, "hyperframes/assets/logo.svg"),
      path.join(project, "assets/logo.svg"),
    );
    await copyFile(
      path.join(root, "node_modules/gsap/dist/gsap.min.js"),
      path.join(project, "assets/vendor/gsap.min.js"),
    );
    for (const file of ["mouse-click.wav", "switch.wav"])
      await copyFile(
        path.join(root, "public/audio", file),
        path.join(project, "assets/audio", file),
      );
  }
  const cuts = [];
  async function crop(file, rect, target) {
    await run("ffmpeg", [
      "-v",
      "error",
      "-y",
      "-i",
      path.join(root, file),
      "-vf",
      `crop=${rect[2]}:${rect[3]}:${rect[0]}:${rect[1]}`,
      "-frames:v",
      "1",
      path.join(project, "assets/native", target),
    ]);
    cuts.push({ source: file, crop: rect, target });
  }
  if (entry.feature === "tab-share") {
    for (let i = 0; i <= 5; i++)
      await crop(`public/native/${version}/search-${i}.png`, [0, 0, 2016, 232], `search-${i}.png`);
    await crop(`public/native/${version}/filtered.png`, [4800, 1992, 592, 296], "share-button.png");
    for (const [from, to] of [
      ["address-visible", "room-before"],
      ["address-hidden", "room-after"],
    ])
      await copyFile(
        path.join(root, `public/native/${version}/address-bar/${from}.png`),
        path.join(project, `assets/native/${to}.png`),
      );
    for (const [from, to] of [
      ["setting-visible", "setting-before"],
      ["setting-hidden", "setting-after"],
    ])
      await crop(
        `public/native/${version}/address-bar/${from}.png`,
        [4880, 100, 2448, 320],
        `${to}.png`,
      );
  }
  const shapes = [];
  const add = (file, rect, radius) => shapes.push([`${file}.png`, rect, radius]);
  if (entry.feature === "tab-share") {
    add("picker", [0, 0, 5440, 2520], 128);
    add("match", [0, 0, 1240, 984], 80);
    for (const file of ["sharing", "switched"]) add(file, [0, 0, 1984, 520], 48);
    for (let i = 0; i <= 5; i++) add(`search-${i}`, [0, 0, 5136, 232], 48);
    add("share-button", [60, 40, 476, 216], 48);
    for (const file of ["setting-before", "setting-after"]) add(file, [100, 88, 2300, 224], 80);
  }
  if (entry.feature === "pinned-tabs")
    for (const asset of native.assets)
      add(path.basename(asset.path, ".png"), [80, 32, 1984, 232], 96);
  if (entry.feature === "calls")
    for (const file of ["connected", "muted", "camera-off"]) add(file, [0, 0, 1984, 272], 48);
  if (entry.feature === "history") {
    for (let i = 0; i <= 6; i++) add(`search-${i}`, [48, 48, 1440, 160], 48);
    add("filtered-rows", [0, 0, 2400, 672], 112);
  }
  if (entry.feature === "archive") add("archive", [0, 0, 1920, 840], 128);
  if (entry.feature === "updates") add("updates", [80, 84, 1984, 356], 80);
  if (entry.feature === "spaces")
    for (const name of ["solid", "glass", "grain"]) add(`${name}-controls`, [0, 0, 1552, 240], 120);
  const cutouts = [];
  for (const [file, rect, radius] of shapes) {
    const cut = cuts.find((item) => item.target === file);
    cutouts.push({
      ...(await isolateNativePng(path.join(project, "assets/native", file), { rect, radius })),
      source: cut?.source ?? `public/native/${version}/${file}`,
      ...(cut ? { crop: cut.crop } : {}),
    });
  }
  if (entry.kind === "video") {
    await run("ffmpeg", [
      "-v",
      "error",
      "-y",
      "-stream_loop",
      "-1",
      "-i",
      path.join(root, "public/audio/music.ogg"),
      "-t",
      String(duration),
      "-af",
      `loudnorm=I=-20:TP=-4:LRA=7,afade=t=in:d=0.15,afade=t=out:st=${duration - 1.5}:d=1.5`,
      "-ar",
      "48000",
      "-ac",
      "2",
      path.join(project, "assets/audio/score.wav"),
    ]);
    let html = await readFile(path.join(project, "index.html"), "utf8");
    html = html.replaceAll(recipe.fixture, version);
    if (!html.includes("assets/audio/score.wav"))
      html = html.replace(
        "</main>",
        `<audio id="score" class="clip" src="assets/audio/score.wav" data-start="0" data-duration="${duration}" data-track-index="20" data-volume="1"></audio></main>`,
      );
    await writeFile(path.join(project, "index.html"), html);
  }
  await cliRun(["check", project, "--json", "--strict"], project, path.join(project, "check.json"));
  if (entry.kind === "video") {
    const job = createRenderJob({
      fps: 60,
      quality: "high",
      format: "mp4",
      crf: 16,
      strictness: "strict",
      pageMotionBlur: "off",
      hdrMode: "force-sdr",
      videoFrameFormat: "png",
      workers: 1,
      useGpu: false,
      producerConfig: resolveConfig({
        fps: { num: 60, den: 1 },
        format: "png",
        concurrency: 1,
        chromePath: browserPath,
        useDrawElement: false,
        enableBrowserPool: false,
        renderReadyTimeout: 45000,
      }),
    });
    const raw = path.join(project, "render.mp4");
    await executeRenderJob(job, project, raw);
    if (job.status !== "complete") throw Error(job.error ?? `Render failed: ${version}`);
    await run("ffmpeg", [
      "-v",
      "error",
      "-y",
      "-i",
      raw,
      "-map",
      "0:v:0",
      "-map",
      "0:a:0",
      "-c:v",
      "copy",
      "-af",
      "loudnorm=I=-16:TP=-1.8:LRA=8",
      "-c:a",
      "aac",
      "-b:a",
      "192k",
      "-ar",
      "48000",
      "-ac",
      "2",
      "-movflags",
      "+faststart",
      "-t",
      String(duration),
      path.join(folder, `${entry.feature}.mp4`),
    ]);
  }
  const posterFrame = metadata.posterFrame;
  const time = posterFrame / 60;
  await cliRun(
    [
      "snapshot",
      project,
      "--at",
      String(time),
      "--keep",
      "--no-end",
      "--json",
      "--output",
      path.join(project, "poster"),
    ],
    project,
    path.join(project, "snapshot.json"),
  );
  await copyFile(
    path.join(project, "poster", `at-${time}s.png`),
    path.join(folder, `${entry.feature}.png`),
  );
  const hashes = {};
  for (const ext of ["png", ...(entry.kind === "video" ? ["mp4"] : [])])
    hashes[`${entry.feature}.${ext}`] = sha(
      await readFile(path.join(folder, `${entry.feature}.${ext}`)),
    );
  const render = {
    schemaVersion: 3,
    engine: "hyperframes",
    release: version,
    kind: entry.kind,
    feature: entry.feature,
    recipe,
    width: 1920,
    height: 1080,
    fps: 60,
    frames: entry.kind === "video" ? Math.round(duration * 60) : 1,
    posterFrame,
    hashes,
    recipeHashes: recipes,
    nativeReceipts: native.receipts,
    cutouts,
  };
  await writeFile(path.join(folder, "render.json"), JSON.stringify(render, null, 2) + "\n");
  console.log(`Rendered HyperFrames ${version}: ${entry.kind} ${entry.feature}`);
}
