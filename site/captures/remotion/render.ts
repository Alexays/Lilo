import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  checkPresentation,
  fileDigest,
  readNativeSource,
} from "./presentation.ts";
import { storyTiming } from "./timing.ts";

const site = fileURLToPath(new URL("../../", import.meta.url));
const source = path.join(site, "src/assets/releases/0.8.0");
const output = process.argv[2] || source;
const timing = storyTiming(readNativeSource(source));

mkdirSync(output, { recursive: true });

const cli = path.join(site, "node_modules/.bin/remotion");
const common = ["captures/remotion/index.tsx"];
const flags = ["--public-dir", "../build/release-motion-assets", "--log=error"];

const run = (args: string[]) =>
  execFileSync(cli, args, { cwd: site, stdio: "inherit" });

run([
  "still",
  ...common,
  "Audio080",
  path.join(output, "share-system-audio-remotion.png"),
  ...flags,
]);

run([
  "still",
  ...common,
  "Sharing080",
  path.join(output, "tab-sharing-controls-remotion.png"),
  `--frame=${timing.posterFrame}`,
  ...flags,
]);

run([
  "render",
  ...common,
  "Sharing080",
  path.join(output, "tab-sharing-controls-remotion.mp4"),
  "--codec=h264",
  "--pixel-format=yuv420p",
  "--color-space=bt709",
  "--crf=12",
  "--audio-codec=aac",
  "--audio-bitrate=192k",
  ...flags,
]);

const digest = (name: string) =>
  fileDigest(readFileSync(path.join(output, name)));

writeFileSync(
  path.join(output, "presentation.json"),
  `${JSON.stringify(
    {
      approved: false,
      media: {
        "share-system-audio": {
          height: 1000,
          kind: "image",
          poster: "share-system-audio-remotion.png",
          posterDigest: digest("share-system-audio-remotion.png"),
          width: 1600,
        },
        "tab-sharing-controls": {
          durationMs: 14_000,
          fps: 60,
          height: 1000,
          kind: "video",
          poster: "tab-sharing-controls-remotion.png",
          posterDigest: digest("tab-sharing-controls-remotion.png"),
          recording: "tab-sharing-controls-remotion.mp4",
          recordingDigest: digest("tab-sharing-controls-remotion.mp4"),
          width: 1600,
        },
      },
      release: "0.8.0",
      schemaVersion: 1,
      sourceArchiveDigest: fileDigest(
        readFileSync(path.join(source, "capture.json"))
      ),
      sourceCaptureDigest: fileDigest(
        readFileSync(path.join(source, "remotion-source.json"))
      ),
    },
    null,
    2
  )}\n`
);

await checkPresentation(output, { sourceDirectory: source });

console.log(
  `Rendered the 0.8.0 proof from fresh native Lilo captures to ${output}; publication awaits visual approval.`
);
