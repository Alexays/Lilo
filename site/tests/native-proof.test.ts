import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import sharp from "sharp";

import type { NativeManifest } from "../captures/native-proof.ts";
import {
  checkNativeArchive,
  checkRequiredReleaseMedia,
  encodeNativeProof,
  nativeArchiveDigest,
  nativeScenarios,
  validateNativeTimeline,
} from "../captures/native-proof.ts";
import { encodeRecording } from "../captures/recording.ts";

const sample = (): NativeManifest => ({
  appBuild: "42",
  appVersion: "0.9.0",
  captureTool: "ScreenCaptureKit.currentProcess",
  capturedAt: "2026-10-28T12:00:00Z",
  checkpoints: ["peek-open", "source-preserved", "peek-reopened"].map(
    (name, i) => ({ atMs: 1000 + i * 1000, name, passed: true })
  ),
  durationMs: 6000,
  frames: Array.from({ length: 90 }, (_, i) => ({
    atMs: i * 33,
    file: `frame-${String(i).padStart(4, "0")}.png`,
  })),
  height: 720,
  scenario: "peek",
  source: "native",
  width: 1120,
});

test("continuous native recordings preserve more than 64 frames", async () => {
  const colors = await Promise.all(
    ["red", "blue"].map((background) =>
      sharp({ create: { background, channels: 3, height: 4, width: 4 } })
        .png()
        .toBuffer()
    )
  );

  const recording = await encodeRecording(
    Array.from({ length: 90 }, (_, i) => ({ delay: 33, image: colors[i % 2] }))
  );

  const metadata = await sharp(recording, { animated: true }).metadata();
  assert.equal(metadata.pages, 90);
  assert.equal(
    metadata.delay?.reduce((sum, delay) => sum + delay, 0),
    2970
  );
  assert.equal(metadata.loop, 1);
});

test("native timeline rejects slideshow timing, failed semantics, and another build version", () => {
  const good = sample();
  assert.equal(validateNativeTimeline(good, "0.9.0").scenario, "peek");
  assert.equal(
    validateNativeTimeline(
      {
        ...good,
        durationMs: 15_000,
        frames: Array.from({ length: 450 }, (_, i) => ({
          atMs: i * 33,
          file: `frame-${String(i).padStart(4, "0")}.png`,
        })),
      },
      "0.9.0"
    ).frames.length,
    450
  );
  assert.throws(
    () =>
      validateNativeTimeline(
        {
          ...good,
          frames: Array.from({ length: 200 }, (_, i) => ({
            atMs: i * 30,
            file: `frame-${String(i).padStart(4, "0")}.png`,
          })),
          height: 1440,
          width: 1920,
        },
        "0.9.0"
      ),
    /pixel budget/u
  );
  assert.throws(() => validateNativeTimeline(good, "0.8.0"), /version/u);
  assert.throws(() =>
    validateNativeTimeline(
      { ...good, frames: good.frames.slice(0, 7) },
      "0.9.0"
    )
  );
  assert.throws(
    () =>
      validateNativeTimeline(
        {
          ...good,
          frames: good.frames.map((f, i) => ({ ...f, atMs: i * 150 })),
        },
        "0.9.0"
      ),
    /motion|timestamp/u
  );
  assert.throws(
    () => validateNativeTimeline({ ...good, checkpoints: [] }, "0.9.0"),
    /checkpoints/u
  );
  assert.throws(
    () =>
      validateNativeTimeline(
        {
          ...good,
          checkpoints: good.checkpoints.map((c) => ({ ...c, passed: false })),
        },
        "0.9.0"
      ),
    /checkpoints/u
  );
  assert.throws(() =>
    validateNativeTimeline(
      {
        ...good,
        frames: good.frames.map((f) => ({ ...f, file: "../frame-0000.png" })),
      },
      "0.9.0"
    )
  );
});

test("native archive fails closed without a completed visual review", () => {
  const directory = mkdtempSync(path.join(tmpdir(), "native-proof-"));

  try {
    assert.throws(() => checkNativeArchive(directory, "0.9.0"));
    const archive = { recordings: {}, release: "0.9.0", schemaVersion: 2 };
    writeFileSync(
      path.join(directory, "capture.json"),
      JSON.stringify(archive)
    );
    assert.throws(
      () => checkNativeArchive(directory, "0.9.0"),
      /visual review/u
    );
    assert.throws(() => checkNativeArchive(directory, "0.8.0"), /mismatched/u);
    assert.equal(
      JSON.parse(readFileSync(path.join(directory, "capture.json"), "utf-8"))
        .release,
      "0.9.0"
    );
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("maintenance releases need no media, while required native highlights fail closed", () => {
  const root = mkdtempSync(path.join(tmpdir(), "native-release-gate-"));
  const stories = path.join(root, "site/src/content/releases");

  try {
    assert.equal(checkRequiredReleaseMedia(root, "0.9.0"), null);
    mkdirSync(stories, { recursive: true });
    const story = path.join(stories, "0.9.0.json");
    writeFileSync(story, JSON.stringify({ highlights: [{ id: "fix" }] }));
    assert.equal(checkRequiredReleaseMedia(root, "0.9.0"), null);
    mkdirSync(path.join(root, "Xcode/Configs"), { recursive: true });
    writeFileSync(
      path.join(root, "Xcode/Configs/Base.xcconfig"),
      "CURRENT_PROJECT_VERSION = 42\n"
    );
    writeFileSync(
      story,
      JSON.stringify({ highlights: [{ capture: { source: "native" } }] })
    );
    assert.throws(
      () => checkRequiredReleaseMedia(root, "0.9.0"),
      /capture\.json/u
    );
    writeFileSync(
      story,
      JSON.stringify({ capture: { source: "native" }, highlights: [] })
    );
    assert.throws(
      () => checkRequiredReleaseMedia(root, "0.9.0"),
      /capture\.json/u
    );
  } finally {
    rmSync(root, { force: true, recursive: true });
  }
});

test("a failed scenario preserves the previous archive; changed media invalidates approval", async () => {
  const root = mkdtempSync(path.join(tmpdir(), "native-proof-atomic-"));
  const output = path.join(root, "archive");

  try {
    const images = await Promise.all(
      Array.from({ length: 90 }, (_, i) =>
        sharp(
          Buffer.from(
            `<svg width="32" height="24"><rect width="32" height="24" fill="rgb(${i * 5},110,70)"/><rect width="12" height="24" fill="white"/></svg>`
          )
        )
          .png()
          .toBuffer()
      )
    );

    for (const scenario of nativeScenarios) {
      const directory = path.join(root, scenario);
      mkdirSync(directory);

      const names = {
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
      }[scenario];

      const manifest = {
        ...sample(),
        checkpoints: names.map((name, i) => ({
          atMs: 300 + i * 400,
          name,
          passed: true,
        })),
        durationMs: 3000,
        frames: images.map((_, i) => ({
          atMs: i === 89 ? 2990 : i * 33,
          file: `frame-${String(i).padStart(4, "0")}.png`,
        })),
        height: 24,
        scenario,
        width: 32,
      };

      writeFileSync(
        path.join(directory, "manifest.json"),
        JSON.stringify(manifest)
      );

      for (const [index, image] of images.entries()) {
        writeFileSync(path.join(directory, manifest.frames[index].file), image);
      }
    }

    mkdirSync(output);
    writeFileSync(path.join(output, "original"), "previous approved archive");
    const finalManifest = path.join(root, "tab-share/manifest.json");
    const original = readFileSync(finalManifest, "utf-8");
    writeFileSync(
      finalManifest,
      JSON.stringify({ ...JSON.parse(original), checkpoints: [] })
    );
    await assert.rejects(
      encodeNativeProof(root, output, "0.9.0", true),
      /checkpoints/u
    );
    assert.equal(
      readFileSync(path.join(output, "original"), "utf-8"),
      "previous approved archive"
    );
    assert.equal(existsSync(path.join(output, "capture.json")), false);
    writeFileSync(finalManifest, original);
    const recordings = await encodeNativeProof(root, output, "0.9.0", true);
    assert.equal(recordings.peek.durationMs, 3090);

    const archive = JSON.parse(
      readFileSync(path.join(output, "capture.json"), "utf-8")
    );

    archive.visualReview = {
      archiveDigest: nativeArchiveDigest(recordings),
      passed: true,
      reviews: Object.fromEntries(
        nativeScenarios.map((scenario) => [
          scenario,
          { passed: true, problems: [] },
        ])
      ),
    };
    writeFileSync(path.join(output, "capture.json"), JSON.stringify(archive));
    assert.equal(checkNativeArchive(output, "0.9.0").release, "0.9.0");
    assert.throws(
      () => checkNativeArchive(output, "0.9.0", true, "43"),
      /another app build/u
    );
    archive.visualReview.reviews.peek.passed = false;
    writeFileSync(path.join(output, "capture.json"), JSON.stringify(archive));
    assert.throws(() => checkNativeArchive(output, "0.9.0"), /visual review/u);
    archive.visualReview.reviews.peek.passed = true;
    writeFileSync(path.join(output, "capture.json"), JSON.stringify(archive));
    writeFileSync(path.join(output, "peek-native.webp"), "modified");
    assert.throws(() => checkNativeArchive(output, "0.9.0"), /modified/u);
  } finally {
    rmSync(root, { force: true, recursive: true });
  }
});
