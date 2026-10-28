import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import sharp from "sharp";
import { z } from "zod";

import { encodeRecording } from "./recording.ts";

export const nativeScenarios = ["peek", "address-bar", "tab-share"] as const;

export type NativeScenario = (typeof nativeScenarios)[number];

const checkpoints: Record<NativeScenario, string[]> = {
  "address-bar": ["address-hidden", "command-bar-available"],
  peek: ["peek-open", "source-preserved", "peek-reopened"],
  "tab-share": [
    "picker-open",
    "tab-shared",
    "stream-delivered",
    "shown-tab-active",
    "share-switched",
    "share-stopped",
  ],
};

export const nativeManifestSchema = z.strictObject({
  appBuild: z.string().min(1),
  appVersion: z.string().regex(/^\d+\.\d+\.\d+$/u),
  captureTool: z.literal("ScreenCaptureKit.currentProcess"),
  capturedAt: z.iso.datetime(),
  checkpoints: z.array(
    z.strictObject({
      atMs: z.number().int().nonnegative(),
      name: z.string(),
      passed: z.boolean(),
    })
  ),
  durationMs: z.number().int().min(3000).max(15_000),
  frames: z
    .array(
      z.strictObject({
        atMs: z.number().int().nonnegative(),
        file: z.string().regex(/^frame-\d{4}\.png$/u),
      })
    )
    .min(30)
    .max(450),
  height: z.number().int().positive().max(1440),
  scenario: z.enum(nativeScenarios),
  source: z.literal("native"),
  width: z.number().int().positive().max(1920),
});

export type NativeManifest = z.infer<typeof nativeManifestSchema>;

const recordingSchema = nativeManifestSchema.omit({ frames: true }).extend({
  frames: z.number().int().min(30).max(450),
  poster: z.string(),
  posterDigest: z.string().length(64),
  quality: z.strictObject({
    decodedFrames: z.number().int().min(24),
    passed: z.literal(true),
    uniqueFrames: z.number().int().min(24),
  }),
  recording: z.string(),
  recordingDigest: z.string().length(64),
  sourceDigest: z.string().length(64),
});

type NativeRecording = z.infer<typeof recordingSchema>;

export const nativePlanSchema = z.strictObject({
  highlights: z
    .array(
      z.strictObject({
        notes: z.array(z.string()).min(1),
        reason: z.string().min(1),
        scenario: z.enum(nativeScenarios),
      })
    )
    .min(1)
    .max(3),
  unsupportedImportantFeatures: z.array(z.string()),
  version: z.string(),
});

const nativeArchiveSchema = z.object({
  fixtureDigest: z.string().optional(),
  plan: nativePlanSchema.optional(),
  recordings: z.record(z.enum(nativeScenarios), recordingSchema),
  release: z.string(),
  schemaVersion: z.literal(2),
  source: z.literal("native"),
  visualReview: z
    .object({
      archiveDigest: z.string(),
      passed: z.boolean(),
      reviews: z.record(
        z.string(),
        z.object({ passed: z.boolean(), problems: z.array(z.string()) })
      ),
    })
    .optional(),
});

export const digest = (bytes: Buffer | string) =>
  createHash("sha256").update(bytes).digest("hex");

export const nativeArchiveDigest = (
  recordings: Record<string, NativeRecording>
) =>
  digest(
    JSON.stringify(
      nativeScenarios.map((scenario) => {
        const m = recordings[scenario];

        return [
          scenario,
          m.appVersion,
          m.appBuild,
          m.sourceDigest,
          m.posterDigest,
          m.recordingDigest,
          m.width,
          m.height,
          m.durationMs,
          m.frames,
          m.quality.passed,
          m.quality.uniqueFrames,
          m.quality.decodedFrames,
        ];
      })
    )
  );

export const validateNativeTimeline = (
  input: NativeManifest,
  version: string
) => {
  const manifest = nativeManifestSchema.parse(input);

  if (manifest.appVersion !== version) {
    throw new Error("Capture app version does not match the release");
  }

  let previous = -1;
  let smoothIntervals = 0;
  const names = new Set<string>();

  for (const frame of manifest.frames) {
    if (
      frame.atMs <= previous ||
      frame.atMs >= manifest.durationMs ||
      names.has(frame.file)
    ) {
      throw new Error("Invalid or repeated frame timestamp/file");
    }

    if (previous >= 0 && frame.atMs - previous <= 67) {
      smoothIntervals += 1;
    }

    previous = frame.atMs;
    names.add(frame.file);
  }

  if (manifest.frames[0].atMs > 100 || smoothIntervals < 24) {
    throw new Error("Recording has insufficient continuous motion samples");
  }

  const passed = new Set(
    manifest.checkpoints
      .filter((c) => c.passed && c.atMs < manifest.durationMs)
      .map((c) => c.name)
  );

  if (
    manifest.checkpoints.some((c) => !c.passed) ||
    !checkpoints[manifest.scenario].every((name) => passed.has(name))
  ) {
    throw new Error("Native feature checkpoints did not pass");
  }

  // A 15-second, 30 fps native window uses 363 million pixels; only one movie is decoded at a time.
  if (manifest.width * manifest.height * manifest.frames.length > 400_000_000) {
    throw new Error("Recording exceeds the decoded pixel budget");
  }

  return manifest;
};

// oxlint-disable eslint/no-await-in-loop -- Encode one bounded movie at a time to cap decoded image memory.
// oxlint-disable-next-line eslint/complexity -- The archive is committed only after every validation succeeds.
export const encodeNativeProof = async (
  framesDirectory: string,
  output: string,
  version: string,
  replace = false
) => {
  if (!/^\d+\.\d+\.\d+$/u.test(version)) {
    throw new Error("Use RELEASE=x.y.z");
  }

  if (existsSync(output) && !replace) {
    throw new Error("Archived media exists; use RECAPTURE=1");
  }

  const parent = path.dirname(output);
  mkdirSync(parent, { recursive: true });
  const stage = mkdtempSync(path.join(parent, ".native-stage-"));

  try {
    const recordings: Record<string, NativeRecording> = {};

    for (const scenario of nativeScenarios) {
      const directory = path.join(framesDirectory, scenario);

      const manifest = validateNativeTimeline(
        JSON.parse(
          readFileSync(path.join(directory, "manifest.json"), "utf-8")
        ),
        version
      );

      if (manifest.scenario !== scenario) {
        throw new Error("Scenario does not match its directory");
      }

      const frames = [];
      const unique = new Set<string>();
      let poster: Buffer | undefined;

      // Sub-11 ms frames are expanded by decoders; finish on a stable, explicit hold.
      const endMs = Math.max(
        manifest.durationMs,
        (manifest.frames.at(-1)?.atMs ?? 0) + 100
      );

      const posterCheckpoint = {
        "address-bar": "address-hidden",
        peek: "peek-open",
        "tab-share": "picker-open",
      }[scenario];

      const posterAt =
        (manifest.checkpoints.find((c) => c.name === posterCheckpoint)?.atMs ??
          0) + 300;

      for (let index = 0; index < manifest.frames.length; index += 1) {
        const frame = manifest.frames[index];
        const image = readFileSync(path.join(directory, frame.file));
        const metadata = await sharp(image).metadata();

        if (
          metadata.width !== manifest.width ||
          metadata.height !== manifest.height
        ) {
          throw new Error("Native frame geometry changed");
        }

        unique.add(digest(image));

        const delay = (manifest.frames[index + 1]?.atMs ?? endMs) - frame.atMs;

        frames.push({ delay, image });

        if (!poster || frame.atMs <= posterAt) {
          poster = image;
        }
      }

      if (unique.size < 24) {
        throw new Error("Recording is static or repeats too few native frames");
      }

      const recording = await encodeRecording(frames);
      const decoded = await sharp(recording, { animated: true }).metadata();
      const durationMs = decoded.delay?.reduce((sum, delay) => sum + delay, 0);

      if (
        decoded.loop !== 1 ||
        (decoded.pages ?? 0) < 24 ||
        durationMs !== endMs - manifest.frames[0].atMs ||
        recording.length > 12_000_000
      ) {
        throw new Error(
          `Encoded ${scenario} failed playback/size checks: ${decoded.pages} frames, loop ${decoded.loop}, ${durationMs}/${endMs - manifest.frames[0].atMs} ms, ${recording.length} bytes`
        );
      }

      if (!poster) {
        throw new Error("Missing native poster");
      }

      const stats = await sharp(poster).stats();

      if (stats.channels.slice(0, 3).every((c) => c.stdev < 8)) {
        throw new Error("Recording poster is blank");
      }

      const filename = `${scenario}-native`;
      writeFileSync(path.join(stage, `${filename}.png`), poster);
      writeFileSync(path.join(stage, `${filename}.webp`), recording);
      writeFileSync(
        path.join(stage, `${scenario}-source.json`),
        `${JSON.stringify(manifest, null, 2)}\n`
      );
      recordings[scenario] = {
        ...manifest,
        durationMs,
        frames: manifest.frames.length,
        poster: `${filename}.png`,
        posterDigest: digest(poster),
        quality: {
          decodedFrames: decoded.pages ?? 0,
          passed: true,
          uniqueFrames: unique.size,
        },
        recording: `${filename}.webp`,
        recordingDigest: digest(recording),
        sourceDigest: digest(JSON.stringify(manifest)),
      };
    }

    writeFileSync(
      path.join(stage, "capture.json"),
      `${JSON.stringify({ recordings, release: version, schemaVersion: 2, source: "native" }, null, 2)}\n`
    );

    // The visual reviewer approves this staged directory before the orchestrator publishes it.
    if (existsSync(output)) {
      rmSync(output, { recursive: true });
    }

    renameSync(stage, output);

    return recordings;
  } finally {
    rmSync(stage, { force: true, recursive: true });
  }
};

// oxlint-enable eslint/no-await-in-loop

// oxlint-disable-next-line eslint/complexity -- Each independent gate must reject before a release is packaged.
export const checkNativeArchive = (
  directory: string,
  version: string,
  requireVisualReview = true,
  expectedBuild = ""
) => {
  const unparsed = JSON.parse(
    readFileSync(path.join(directory, "capture.json"), "utf-8")
  );

  if (unparsed.schemaVersion !== 2 || unparsed.release !== version) {
    throw new Error("Missing or mismatched native archive");
  }

  if (requireVisualReview && unparsed.visualReview?.passed !== true) {
    throw new Error("Native media has not passed visual review");
  }

  const archive = nativeArchiveSchema.parse(unparsed);

  if (archive.release !== version) {
    throw new Error("Missing or mismatched native archive");
  }

  if (
    requireVisualReview &&
    (archive.visualReview?.passed !== true ||
      archive.visualReview?.archiveDigest !==
        nativeArchiveDigest(archive.recordings) ||
      !nativeScenarios.every(
        (scenario) =>
          archive.visualReview?.reviews[scenario]?.passed === true &&
          archive.visualReview.reviews[scenario].problems.length === 0
      ))
  ) {
    throw new Error("Native media has not passed visual review");
  }

  for (const scenario of nativeScenarios) {
    const entry = archive.recordings?.[scenario];

    const manifest = validateNativeTimeline(
      JSON.parse(
        readFileSync(path.join(directory, `${scenario}-source.json`), "utf-8")
      ),
      version
    );

    if (expectedBuild && manifest.appBuild !== expectedBuild) {
      throw new Error("Native recording belongs to another app build");
    }

    if (
      manifest.scenario !== scenario ||
      entry?.quality?.passed !== true ||
      entry.sourceDigest !== digest(JSON.stringify(manifest))
    ) {
      throw new Error("Invalid native quality/provenance record");
    }

    for (const [extension, expected] of [
      ["png", entry.posterDigest],
      ["webp", entry.recordingDigest],
    ]) {
      if (
        digest(
          readFileSync(path.join(directory, `${scenario}-native.${extension}`))
        ) !== expected
      ) {
        throw new Error("Archived native media was modified");
      }
    }
  }

  return archive;
};

export const checkRequiredReleaseMedia = (
  root: string,
  version: string,
  override = ""
) => {
  if (!/^\d+\.\d+\.\d+$/u.test(version)) {
    throw new Error("Use RELEASE=x.y.z");
  }

  const directory =
    override || path.join(root, "site/src/assets/releases", version);

  const storyFile = path.join(
    root,
    "site/src/content/releases",
    `${version}.json`
  );

  const story = existsSync(storyFile)
    ? JSON.parse(readFileSync(storyFile, "utf-8"))
    : {};

  const captures = [
    story.capture,
    ...(story.highlights ?? []).map(
      (h: { capture?: { source?: string } }) => h.capture
    ),
  ];

  const archive = existsSync(path.join(directory, "capture.json"))
    ? JSON.parse(readFileSync(path.join(directory, "capture.json"), "utf-8"))
    : null;

  if (
    !override &&
    !captures.some((c) => c?.source === "native") &&
    archive?.schemaVersion !== 2
  ) {
    return null;
  }

  const build = readFileSync(
    path.join(root, "Xcode/Configs/Base.xcconfig"),
    "utf-8"
  ).match(/^CURRENT_PROJECT_VERSION\s*=\s*(?<build>\d+)/mu)?.groups?.build;

  if (!build) {
    throw new Error("Missing app build identity");
  }

  return checkNativeArchive(directory, version, true, build);
};

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const root = fileURLToPath(new URL("../../", import.meta.url));
  const version = process.env.LILO_CAPTURE_VERSION ?? "";

  const output =
    process.env.LILO_CAPTURE_OUTPUT ||
    path.join(root, "site/src/assets/releases", version);

  if (process.argv[2] === "check") {
    checkRequiredReleaseMedia(
      root,
      version,
      process.env.LILO_CAPTURE_OUTPUT || ""
    );
  } else {
    await encodeNativeProof(
      process.env.LILO_CAPTURE_FRAMES ?? "",
      output,
      version,
      process.env.LILO_CAPTURE_REPLACE === "1"
    );
  }
}
