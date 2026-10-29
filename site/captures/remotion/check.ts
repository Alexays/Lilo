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

  const audio = result.streams.find(
    (item: { codec_type: string }) => item.codec_type === "audio"
  );

  if (
    !audio ||
    audio.codec_name !== "aac" ||
    audio.channels !== 2 ||
    Number(audio.sample_rate) !== 48_000
  ) {
    throw new Error("The MP4 must contain the stereo sound design track");
  }

  const pcm = execFileSync(
    path.join(site, "node_modules/.bin/remotion"),
    [
      "ffmpeg",
      "-v",
      "error",
      "-i",
      path.join(output, media.recording),
      "-vn",
      "-ar",
      "48000",
      "-ac",
      "2",
      "-c:a",
      "pcm_s16le",
      "-f",
      "wav",
      "pipe:1",
    ],
    { maxBuffer: 10_000_000 }
  );

  const start = pcm.indexOf("data", 12) + 8;

  if (start < 20 || start >= pcm.length) {
    throw new Error("Cannot decode the sound design track");
  }

  const samples = pcm.subarray(start);
  let energy = 0;
  let peak = 0;

  for (let offset = 0; offset + 1 < samples.length; offset += 2) {
    const sample = samples.readInt16LE(offset) / 32_768;
    energy += sample * sample;
    peak = Math.max(peak, Math.abs(sample));
  }

  const rms = Math.sqrt(energy / (samples.length / 2));

  if (rms < 0.01 || peak > 0.98) {
    throw new Error("The sound design is silent, too quiet or clipped");
  }

  console.log(
    `Sound design: RMS ${(20 * Math.log10(rms)).toFixed(1)} dBFS, peak ${(20 * Math.log10(peak)).toFixed(1)} dBFS.`
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
