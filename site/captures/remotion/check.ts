import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { checkPresentation } from "./presentation.ts";

const site = fileURLToPath(new URL("../../", import.meta.url));
const source = path.join(site, "src/assets/releases/0.8.0");
const output = process.argv[2] || source;

const presentation = await checkPresentation(output, {
  sourceDirectory: source,
});

for (const media of Object.values(presentation.media)) {
  if (media.kind !== "video") {
    continue;
  }

  const result = JSON.parse(
    execFileSync(
      path.join(site, "node_modules/.bin/remotion"),
      [
        "ffprobe",
        "-v",
        "quiet",
        "-show_streams",
        "-show_format",
        "-print_format",
        "json",
        path.join(output, media.recording),
      ],
      { cwd: site, encoding: "utf-8" }
    )
  );

  const stream = result.streams.find(
    (item: { codec_type: string }) => item.codec_type === "video"
  );

  if (
    !stream ||
    stream.codec_name !== "h264" ||
    stream.width !== media.width ||
    stream.height !== media.height ||
    stream.avg_frame_rate !== "60/1" ||
    Math.abs(Number(result.format.duration) * 1000 - media.durationMs) > 40
  ) {
    throw new Error(
      "Invalid rendered video dimensions, codec, frame rate or duration"
    );
  }
}

console.log(
  "Native presentation assets, hashes, dimensions and MP4 decode metadata passed."
);
