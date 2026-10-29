import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import sharp from "sharp";

import { readApprovedArchive } from "../authored-archive.ts";

const source = new URL("../../src/assets/releases/0.8.0/", import.meta.url);

const output = new URL(
  "../../../build/release-motion-assets/",
  import.meta.url
);

readApprovedArchive(fileURLToPath(source));

mkdirSync(new URL("tab-sharing/", output), { recursive: true });

const movie = readFileSync(new URL("tab-sharing-controls-native.webp", source));
const metadata = await sharp(movie, { animated: true }).metadata();
const delays = metadata.delay ?? [];
let atMs = 0;
const timeline: { atMs: number; file: string }[] = [];

for (let index = 0; index < delays.length; index += 1) {
  const name = `tab-sharing/${String(index).padStart(4, "0")}.png`;
  const target = new URL(name, output);
  // oxlint-disable-next-line no-await-in-loop -- Decode sequentially to bound native frame memory.
  await sharp(movie, { page: index, pages: 1 })
    .png()
    .toFile(fileURLToPath(target));
  timeline.push({ atMs, file: name });
  atMs += delays[index];
}

writeFileSync(new URL("timeline.json", output), JSON.stringify(timeline));

await sharp(fileURLToPath(new URL("share-system-audio-native.png", source)))
  .png()
  .toFile(fileURLToPath(new URL("audio.png", output)));

const samples = await Promise.all(
  Array.from({ length: 15 }, async (_, second) => {
    const frame =
      timeline.findLast((item) => item.atMs <= second * 1000) ?? timeline[0];

    return {
      input: await sharp(fileURLToPath(new URL(frame.file, output)))
        .resize(336, 216)
        .png()
        .toBuffer(),
      left: (second % 3) * 336,
      top: Math.floor(second / 3) * 216,
    };
  })
);

await sharp({
  create: { background: "#eee", channels: 4, height: 1080, width: 1008 },
})
  .composite(samples)
  .png()
  .toFile(fileURLToPath(new URL("source-contact.png", output)));

console.log(
  `Prepared ${timeline.length} real native frames (${atMs}ms); original archives unchanged.`
);
