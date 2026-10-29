import { copyFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { readApprovedArchive } from "../authored-archive.ts";
import { nativeSourceDirectory, readNativeSource } from "./presentation.ts";
import { soundtrack } from "./soundtrack.ts";
import { storyTiming } from "./timing.ts";

const source = fileURLToPath(
  new URL("../../src/assets/releases/0.8.0/", import.meta.url)
);

const output = fileURLToPath(
  new URL("../../../build/release-motion-assets/", import.meta.url)
);

readApprovedArchive(source);

const native = readNativeSource(source);

mkdirSync(output, { recursive: true });

for (const capture of [...native.captures, native.footage]) {
  copyFileSync(
    path.join(nativeSourceDirectory(native.release), capture.file),
    path.join(output, capture.file)
  );
}

writeFileSync(path.join(output, "native-source.json"), JSON.stringify(native));

const timing = storyTiming(native);

writeFileSync(
  path.join(output, "soundtrack.wav"),
  soundtrack(timing.shownAt, timing.switchedAt)
);

console.log(
  "Prepared fresh 4x native UI states, footage at verified native density and original stereo sound design."
);
