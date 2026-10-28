import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import sharp from "sharp";
import { z } from "zod";

import { parseReleaseStories } from "../src/lib/release-stories.ts";
import { encodeRecording } from "./recording.ts";
import { captureArchiveState } from "./release-capture.ts";

const frameName = z.string().regex(/^[a-z0-9-]+\.png$/u);

const manifestSchema = z.strictObject({
  appBuild: z.string().min(1),
  appVersion: z.string().min(1),
  capturedAt: z.iso.datetime(),
  frames: z
    .array(
      z.strictObject({
        delay: z.number().int().positive().max(10_000),
        file: frameName,
      })
    )
    .min(2)
    .max(64),
  pages: z
    .array(
      z.url().refine((value) => {
        const url = new URL(value);

        return (
          url.protocol === "https:" &&
          !url.username &&
          !url.password &&
          !url.search &&
          !url.hash
        );
      }, "Use canonical public HTTPS URLs without credentials or query strings")
    )
    .min(1),
  poster: frameName,
});

export const importNativeCapture = async (
  root: string,
  version: string,
  manifestPath: string,
  replace = false
) => {
  const story = parseReleaseStories(
    readFileSync(path.join(root, "CHANGELOG.md"), "utf-8"),
    [
      JSON.parse(
        readFileSync(
          path.join(root, "site/src/content/releases", `${version}.json`),
          "utf-8"
        )
      ),
    ]
  ).get(version);

  if (story?.capture.source !== "native") {
    throw new Error("The release story must select a native capture");
  }

  const directory = path.join(root, "site/src/assets/releases", version);

  if (captureArchiveState(directory, "native") !== "missing" && !replace) {
    throw new Error("Archived captures exist; use RECAPTURE=1 to replace them");
  }

  const manifest = manifestSchema.parse(
    JSON.parse(readFileSync(manifestPath, "utf-8"))
  );

  const durationMs = manifest.frames.reduce(
    (sum, frame) => sum + frame.delay,
    0
  );

  if (
    manifest.appVersion !== version ||
    durationMs > 30_000 ||
    !manifest.frames.some((frame) => frame.file === manifest.poster)
  ) {
    throw new Error(
      "Use this release's native frames, a matching poster, and at most 30 seconds"
    );
  }

  const hash = createHash("sha256");

  const posterSize = await sharp(
    path.join(path.dirname(manifestPath), manifest.poster)
  ).metadata();

  if (!posterSize.width || !posterSize.height) {
    throw new Error("The native poster has no image dimensions");
  }

  const width = Math.min(1440, posterSize.width);
  const height = Math.round((width * posterSize.height) / posterSize.width);

  const frames = await Promise.all(
    manifest.frames.map(async (frame) => {
      const image = readFileSync(
        path.join(path.dirname(manifestPath), frame.file)
      );

      hash.update(frame.file).update("\0").update(image);

      const scaled = await sharp(image)
        .resize({ background: "#1a1925", fit: "contain", height, width })
        .png()
        .toBuffer({ resolveWithObject: true });

      return {
        ...frame,
        height: scaled.info.height,
        image: scaled.data,
        width: scaled.info.width,
      };
    })
  );

  const [first] = frames;

  if (
    !frames.every(
      (frame) => frame.width === first.width && frame.height === first.height
    )
  ) {
    throw new Error("Native frames must have matching dimensions");
  }

  const poster = frames.find((frame) => frame.file === manifest.poster);
  const recording = await encodeRecording(frames);

  const metadata = {
    appBuild: manifest.appBuild,
    appVersion: manifest.appVersion,
    captureTool: "cua_repl",
    capturedAt: manifest.capturedAt,
    contextTool: "lilo-mcp",
    durationMs,
    files: ["peek-native.png", "peek-native.webp"],
    height: first.height,
    release: version,
    scenario: "peek",
    source: "native",
    sourceDigest: hash.digest("hex"),
    sourcePages: manifest.pages,
    width: first.width,
  };

  mkdirSync(directory, { recursive: true });
  writeFileSync(
    path.join(directory, "peek-native.png"),
    poster?.image ?? first.image
  );
  writeFileSync(path.join(directory, "peek-native.webp"), recording);
  writeFileSync(
    path.join(directory, "capture.json"),
    `${JSON.stringify(metadata, null, 2)}\n`
  );

  return metadata;
};

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  await importNativeCapture(
    fileURLToPath(new URL("../../", import.meta.url)),
    process.env.LILO_CAPTURE_VERSION ?? "",
    process.env.LILO_CAPTURE_FRAMES ?? "",
    process.env.LILO_CAPTURE_REPLACE === "1"
  );
}
