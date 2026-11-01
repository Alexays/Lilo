import { bundle } from "@remotion/bundler";
import { openBrowser, renderMedia, renderStill, selectComposition } from "@remotion/renderer";
import { createHash } from "node:crypto";
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const root = path.dirname(new URL(import.meta.url).pathname);
const catalog = JSON.parse(await readFile(path.join(root, "backlog.json"), "utf8"));
if (
  process.env.LILO_RELEASE_MEDIA_VERSION &&
  !Object.hasOwn(catalog.releases, process.env.LILO_RELEASE_MEDIA_VERSION)
)
  throw Error("Unknown release media version");
const recipeHashes = {};
for (const file of ["src/Root.tsx", "src/Backlog.tsx", "src/Motion.tsx", "package-lock.json"])
  recipeHashes[file] = createHash("sha256")
    .update(await readFile(path.join(root, file)))
    .digest("hex");
const selected = Object.entries(catalog.releases).filter(
  ([version, e]) =>
    e.kind !== "none" &&
    (!process.env.LILO_RELEASE_MEDIA_VERSION || process.env.LILO_RELEASE_MEDIA_VERSION === version),
);
const serveUrl = await bundle({
  entryPoint: path.join(root, "src/Root.tsx"),
  publicDir: path.join(root, "public"),
});
const browser = await openBrowser("chrome", { logLevel: "error" });
try {
  for (const [version, entry] of selected) {
    const previous = JSON.parse(
      await readFile(path.join(root, "assets", version, "render.json"), "utf8").catch((error) => {
        if (error.code === "ENOENT") return "null";
        throw error;
      }),
    );
    if (previous?.approved === true) {
      console.log(`Preserved approved ${version} media`);
      continue;
    }
    const nativeBytes = await readFile(path.join(root, "public/native", version, "capture.json"));
    const native = JSON.parse(nativeBytes);
    for (const asset of native.assets) {
      const data = await readFile(path.join(root, "public/native", version, asset.file));
      if (createHash("sha256").update(data).digest("hex") !== asset.sha256)
        throw Error(`Native pixels changed: ${version}/${asset.file}`);
    }
    const composition = await selectComposition({
      serveUrl,
      id: entry.feature,
      puppeteerInstance: browser,
    });
    const output = path.join(root, "assets", version);
    await mkdir(output, { recursive: true });
    const common = {
      serveUrl,
      composition,
      puppeteerInstance: browser,
      logLevel: "error",
      isProduction: false,
    };
    const started = performance.now();
    const posterFrame =
      entry.kind === "video" ? Math.round(composition.durationInFrames * 0.88) : 0;
    if (entry.kind === "video") {
      await renderMedia({
        ...common,
        codec: "h264",
        crf: 16,
        imageFormat: "png",
        pixelFormat: "yuv420p",
        colorSpace: "bt709",
        audioCodec: "aac",
        audioBitrate: "192k",
        sampleRate: 48000,
        enforceAudioTrack: true,
        x264Preset: "slow",
        concurrency: 4,
        outputLocation: path.join(output, `${entry.feature}.mp4`),
      });
    }
    await renderStill({
      ...common,
      frame: posterFrame,
      imageFormat: "png",
      output: path.join(output, `${entry.feature}.png`),
    });
    await copyFile(
      path.join(root, "public/native", version, "capture.json"),
      path.join(output, "capture.json"),
    );
    const files = [
      `${entry.feature}.png`,
      ...(entry.kind === "video" ? [`${entry.feature}.mp4`] : []),
    ];
    const hashes = {};
    for (const file of files)
      hashes[file] = createHash("sha256")
        .update(await readFile(path.join(output, file)))
        .digest("hex");
    await writeFile(
      path.join(output, "render.json"),
      JSON.stringify(
        {
          schemaVersion: 1,
          release: version,
          kind: entry.kind,
          feature: entry.feature,
          appVersion: native.appVersion,
          appBuild: native.appBuild,
          productSourceCommit: native.productSourceCommit,
          width: composition.width,
          height: composition.height,
          fps: composition.fps,
          frames: entry.kind === "video" ? composition.durationInFrames : 1,
          posterFrame,
          renderMilliseconds: performance.now() - started,
          hashes,
          recipeHashes,
          nativeReceiptSha256: createHash("sha256").update(nativeBytes).digest("hex"),
          approved: false,
          publication: "blocked",
        },
        null,
        2,
      ) + "\n",
    );
    console.log(`Rendered ${version}: ${entry.kind} ${entry.feature}`);
  }
} finally {
  await browser.close({ silent: true });
}
