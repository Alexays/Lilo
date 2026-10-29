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
  release: z.literal("0.8.0"),
  schemaVersion: z.literal(1),
  sourceArchiveDigest: hash,
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

export const checkPresentation = (
  directory: string | URL,
  options: { publication?: boolean; sourceDirectory?: string | URL } = {}
) => {
  const folder =
    directory instanceof URL ? fileURLToPath(directory) : directory;

  const presentation = presentationSchema.parse(
    JSON.parse(readFileSync(path.join(folder, "presentation.json"), "utf-8"))
  );

  const sourceFolder = options.sourceDirectory ?? folder;

  const sourceFile = path.join(
    sourceFolder instanceof URL ? fileURLToPath(sourceFolder) : sourceFolder,
    "capture.json"
  );

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

  if (options.publication && !presentation.approved) {
    throw new Error("Presentation is awaiting visual approval");
  }

  return presentation;
};
