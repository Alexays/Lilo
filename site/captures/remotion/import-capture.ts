import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { fileDigest } from "./presentation.ts";

const site = fileURLToPath(new URL("../../", import.meta.url));
const input = path.join(site, "../build/release-motion-capture");
const source = path.join(site, "captures/remotion/source-0.8.0");
const release = path.join(site, "src/assets/releases/0.8.0");

mkdirSync(source, { recursive: true });

const captures = [];

for (const scenario of ["share-system-audio", "tab-sharing-controls"]) {
  const folder = path.join(input, scenario);

  const manifest = JSON.parse(
    readFileSync(path.join(folder, "manifest.json"), "utf-8")
  );

  if (
    manifest.source !== "native" ||
    manifest.checkpoints.some((entry: { passed: boolean }) => !entry.passed)
  ) {
    throw new Error("Native capture checks failed");
  }

  const names =
    scenario === "share-system-audio"
      ? ["audio-ready"]
      : [
          "picker-open",
          "search-finds-brief",
          "call-card-names-brief",
          "share-shown-tab-available",
          "share-switched-to-agenda",
          "agenda-sharing-preview",
        ];

  for (const name of names) {
    const state = JSON.parse(
      readFileSync(path.join(folder, `${name}.json`), "utf-8")
    );

    const bytes = readFileSync(path.join(folder, state.file));

    if (
      state.width < state.logicalWidth * 4 ||
      state.height < state.logicalHeight * 4 ||
      bytes.readUInt32BE(16) !== state.width ||
      bytes.readUInt32BE(20) !== state.height
    ) {
      throw new Error("Native state resolution is too small");
    }

    copyFileSync(path.join(folder, state.file), path.join(source, state.file));
    captures.push({
      ...state,
      appBuild: manifest.appBuild,
      appVersion: manifest.appVersion,
      checkpoint: name,
      digest: fileDigest(bytes),
      inputDigest: manifest.inputDigest,
      scenario,
      scenarioDigest: manifest.scenarioDigest,
    });
  }
}

const folder = path.join(input, "tab-sharing-controls");

const manifest = JSON.parse(
  readFileSync(path.join(folder, "manifest.json"), "utf-8")
);

const frames: { file: string; atMs: number }[] = manifest.frames;
const lastFrame = frames.at(-1);

if (!lastFrame) {
  throw new Error("Native footage has no frames");
}

const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
const concat = path.join(input, "source.ffconcat");

writeFileSync(
  concat,
  `ffconcat version 1.0\n${frames.map((frame, index) => `file ${quote(path.join(folder, frame.file))}\nduration ${Math.max(1, (frames[index + 1]?.atMs ?? manifest.durationMs) - frame.atMs) / 1000}`).join("\n")}\nfile ${quote(path.join(folder, lastFrame.file))}\n`
);

const file = "tab-sharing-source.mp4";

execFileSync(
  path.join(site, "node_modules/.bin/remotion"),
  [
    "ffmpeg",
    "-y",
    "-loglevel",
    "error",
    "-f",
    "concat",
    "-safe",
    "0",
    "-i",
    concat,
    "-fps_mode",
    "vfr",
    "-c:v",
    "libx264",
    "-crf",
    "10",
    "-pix_fmt",
    "yuv420p",
    "-movflags",
    "+faststart",
    path.join(source, file),
  ],
  { cwd: site, stdio: "inherit" }
);

writeFileSync(
  path.join(release, "remotion-source.json"),
  `${JSON.stringify({ captures, footage: { ...manifest, digest: fileDigest(readFileSync(path.join(source, file))), file, frames: undefined }, release: "0.8.0", schemaVersion: 1, source: "native" }, null, 2)}\n`
);

console.log(
  `Imported ${captures.length} fresh 4x native states and continuous native footage; historical 0.8.0 sources are unchanged.`
);
