import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { z } from "zod";

const hash = z.string().regex(/^[a-f0-9]{64}$/u);
const filename = z.string().regex(/^[a-z0-9-]+\.(?:png|mp4)$/u);

const dimensions = {
  height: z.number().int().positive(),
  poster: filename,
  posterDigest: hash,
  width: z.number().int().positive(),
};

export const presentationSchema = z.strictObject({
  approved: z.boolean(),
  media: z.record(
    z.string(),
    z.discriminatedUnion("kind", [
      z.strictObject({ ...dimensions, kind: z.literal("image") }),
      z.strictObject({
        ...dimensions,
        durationMs: z.number().positive(),
        fps: z.literal(60),
        kind: z.literal("video"),
        recording: filename,
        recordingDigest: hash,
      }),
    ])
  ),
  release: z.string().regex(/^\d+\.\d+\.\d+$/u),
  schemaVersion: z.literal(1),
  sourceArchiveDigest: hash,
  sourceCaptureDigest: hash.optional(),
});

export type ReleasePresentation = z.infer<typeof presentationSchema>;

export const fileDigest = (value: Uint8Array) =>
  createHash("sha256").update(value).digest("hex");

const assetBytes = (folder: string, name: string, expected: string) => {
  const asset = path.join(folder, name);

  if (!existsSync(asset)) {
    throw new Error(`Missing presentation asset: ${name}`);
  }

  const data = readFileSync(asset);

  if (fileDigest(data) !== expected) {
    throw new Error(`Changed presentation asset: ${name}`);
  }

  return data;
};

const nativeSourceSchema = z.object({
  captures: z
    .array(
      z.object({
        appBuild: z.string(),
        appVersion: z.string(),
        captureTool: z.literal("WKWebView.takeSnapshot"),
        capturedAt: z.iso.datetime(),
        checkpoint: z.string(),
        digest: hash,
        file: z.string().regex(/^[a-z0-9-]+\.png$/u),
        height: z.number().min(2600),
        inputDigest: hash,
        logicalHeight: z.number().min(650),
        logicalWidth: z.number().min(1000),
        regions: z.record(
          z.string(),
          z.tuple([z.number(), z.number(), z.number(), z.number()])
        ),
        scenario: z.string(),
        scenarioDigest: hash,
        width: z.number().min(4000),
      })
    )
    .min(7),
  footage: z.object({
    appBuild: z.string(),
    appVersion: z.string(),
    captureTool: z.literal("ScreenCaptureKit.currentProcess"),
    capturedAt: z.iso.datetime(),
    checkpoints: z.array(
      z.object({ atMs: z.number(), name: z.string(), passed: z.literal(true) })
    ),
    digest: hash,
    durationMs: z.number().positive(),
    file: z.string().regex(/^[a-z0-9-]+\.mp4$/u),
    height: z.number().min(720),
    logicalHeight: z.number().min(650),
    logicalWidth: z.number().min(1000),
    maxContentScale: z.number().positive().max(1.001),
    nativePixelScale: z.number().min(1).max(4),
    source: z.literal("native"),
    width: z.number().min(1120),
  }),
  release: z.string().regex(/^\d+\.\d+\.\d+$/u),
  schemaVersion: z.literal(1),
  source: z.literal("native"),
});

export type NativeCaptureSource = z.infer<typeof nativeSourceSchema>;

export const nativeSourceDirectory = (release: string) =>
  fileURLToPath(new URL(`source-${release}/`, import.meta.url));

export const readNativeSource = (directory: string) => {
  const source = nativeSourceSchema.parse(
    JSON.parse(
      readFileSync(path.join(directory, "remotion-source.json"), "utf-8")
    )
  );

  for (const capture of source.captures) {
    const bytes = assetBytes(
      nativeSourceDirectory(source.release),
      capture.file,
      capture.digest
    );

    if (
      bytes.readUInt32BE(16) !== capture.width ||
      bytes.readUInt32BE(20) !== capture.height
    ) {
      throw new Error("Native source dimensions changed");
    }

    if (
      capture.width < capture.logicalWidth * 4 ||
      capture.height < capture.logicalHeight * 4
    ) {
      throw new Error("Native UI capture density is too low");
    }

    if (
      fileDigest(
        readFileSync(path.join(directory, `${capture.scenario}-scenario.json`))
      ) !== capture.scenarioDigest
    ) {
      throw new Error("Native scenario changed");
    }
  }

  assetBytes(
    nativeSourceDirectory(source.release),
    source.footage.file,
    source.footage.digest
  );

  if (
    source.footage.width >
      source.footage.logicalWidth * source.footage.nativePixelScale ||
    source.footage.height >
      source.footage.logicalHeight * source.footage.nativePixelScale
  ) {
    throw new Error("Native footage enlarged its backing pixels");
  }

  return source;
};

const checkFreshCapture = (
  sourceFolder: string,
  presentation: ReleasePresentation
) => {
  if (!Object.keys(presentation.media).length) {
    return;
  }

  if (!presentation.sourceCaptureDigest) {
    throw new Error("Fresh native source is missing");
  }

  if (
    fileDigest(
      readFileSync(path.join(sourceFolder, "remotion-source.json"))
    ) !== presentation.sourceCaptureDigest
  ) {
    throw new Error("Fresh native source changed");
  }

  if (readNativeSource(sourceFolder).release !== presentation.release) {
    throw new Error("Fresh native source release mismatch");
  }
};

export const checkPresentation = (
  directory: string | URL,
  options: { publication?: boolean; sourceDirectory?: string | URL } = {}
) => {
  const folder =
    directory instanceof URL ? fileURLToPath(directory) : directory;

  const presentation = presentationSchema.parse(
    JSON.parse(readFileSync(path.join(folder, "presentation.json"), "utf-8"))
  );

  if (options.publication && !presentation.approved) {
    throw new Error("Presentation is awaiting visual approval");
  }

  const sourceLocation = options.sourceDirectory ?? folder;

  const sourceFolder =
    sourceLocation instanceof URL
      ? fileURLToPath(sourceLocation)
      : sourceLocation;

  const sourceFile = path.join(sourceFolder, "capture.json");

  if (
    !existsSync(sourceFile) ||
    fileDigest(readFileSync(sourceFile)) !== presentation.sourceArchiveDigest
  ) {
    throw new Error("Native source archive is missing or changed");
  }

  const archive = JSON.parse(readFileSync(sourceFile, "utf-8"));

  if (archive.release !== presentation.release || archive.source !== "native") {
    throw new Error("Native source release mismatch");
  }

  checkFreshCapture(sourceFolder, presentation);

  if (
    Object.keys(presentation.media).toSorted().join(",") !==
    Object.keys(archive.recordings).toSorted().join(",")
  ) {
    throw new Error("Presentation must cover the native release highlights");
  }

  for (const media of Object.values(presentation.media)) {
    const image = assetBytes(folder, media.poster, media.posterDigest);

    if (
      image.toString("hex", 0, 8) !== "89504e470d0a1a0a" ||
      image.readUInt32BE(16) !== media.width ||
      image.readUInt32BE(20) !== media.height
    ) {
      throw new Error("Presentation image dimensions changed");
    }

    if (
      media.kind === "video" &&
      assetBytes(folder, media.recording, media.recordingDigest).toString(
        "ascii",
        4,
        8
      ) !== "ftyp"
    ) {
      throw new Error("Invalid MP4 presentation");
    }
  }

  return presentation;
};
