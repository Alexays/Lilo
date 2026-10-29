import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import sharp from "sharp";

import { importNativeCapture } from "../captures/import-native.ts";
import { encodeRecording } from "../captures/recording.ts";
import {
  captureArchiveState,
  captureSourceDigest,
} from "../captures/release-capture.ts";

test("recordings preserve multiple frames, their timing and a single playback", async () => {
  const images = await Promise.all(
    ["red", "blue"].map((background) =>
      sharp({ create: { background, channels: 3, height: 4, width: 4 } })
        .png()
        .toBuffer()
    )
  );

  const recording = await encodeRecording([
    { delay: 120, image: images[0] },
    { delay: 340, image: images[1] },
  ]);

  const metadata = await sharp(recording, { animated: true }).metadata();
  assert.equal(metadata.format, "webp");
  assert.equal(metadata.pages, 2);
  assert.equal(metadata.pageHeight, 4);
  assert.equal(metadata.loop, 1);
  assert.deepEqual(metadata.delay, [120, 340]);
  assert.throws(() => encodeRecording([]), /2 to 450 frames/u);
  assert.throws(
    () =>
      encodeRecording([
        { delay: 0, image: images[0] },
        { delay: 50, image: images[1] },
      ]),
    /positive delays/u
  );
});

test("recognizes incomplete capture archives without treating them as new", () => {
  const directory = mkdtempSync(path.join(tmpdir(), "lilo-capture-"));

  try {
    assert.equal(captureArchiveState(directory), "missing");
    writeFileSync(path.join(directory, "peek-en-light.png"), "older image");
    assert.equal(captureArchiveState(directory), "incomplete");
    writeFileSync(path.join(directory, "capture.json"), "{}");
    assert.equal(captureArchiveState(directory), "incomplete");

    for (const name of [
      "peek-en-dark.png",
      "peek-fr-light.png",
      "peek-fr-dark.png",
      "peek-en-light.webp",
      "peek-en-dark.webp",
      "peek-fr-light.webp",
      "peek-fr-dark.webp",
    ]) {
      writeFileSync(path.join(directory, name), "image");
    }

    assert.equal(captureArchiveState(directory), "complete");
    unlinkSync(path.join(directory, "peek-en-light.png"));
    assert.equal(captureArchiveState(directory), "incomplete");
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("recognizes a native archive without requiring simulated locale variants", () => {
  const directory = mkdtempSync(path.join(tmpdir(), "lilo-native-capture-"));

  try {
    writeFileSync(path.join(directory, "capture.json"), "{}");
    writeFileSync(path.join(directory, "peek-native.png"), "poster");
    assert.equal(captureArchiveState(directory, "native"), "incomplete");
    writeFileSync(path.join(directory, "peek-native.webp"), "recording");
    assert.equal(captureArchiveState(directory, "native"), "complete");
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("imports native frames with real provenance and protects the reviewed archive", async () => {
  const root = mkdtempSync(path.join(tmpdir(), "lilo-native-import-"));
  const content = path.join(root, "site/src/content/releases");
  const directory = path.join(root, "site/src/assets/releases/0.9.0");
  const manifestPath = path.join(root, "manifest.json");
  const text = { en: "Preview a link.", fr: "Ouvrez un lien en aperçu." };

  const manifest = {
    appBuild: "42",
    appVersion: "0.9.0",
    capturedAt: "2026-10-28T12:00:00Z",
    frames: [
      { delay: 100, file: "closed.png" },
      { delay: 200, file: "open.png" },
    ],
    pages: ["https://example.com/guide"],
    poster: "open.png",
  };

  try {
    mkdirSync(content, { recursive: true });
    writeFileSync(
      path.join(root, "CHANGELOG.md"),
      "# Changelog\n\n## [0.9.0] - 2026-10-28\n\n### Added\n\n- Preview a link.\n"
    );
    writeFileSync(
      path.join(content, "0.9.0.json"),
      JSON.stringify({
        capture: { highlight: "peek", scenario: "peek", source: "native" },
        highlights: [
          { body: text, id: "peek", notes: ["Preview a link."], title: text },
        ],
        introduction: text,
        title: text,
        version: "0.9.0",
      })
    );
    await Promise.all(
      ["closed", "open"].map(async (name, index) => {
        await sharp({
          create: {
            background: index === 0 ? "red" : "blue",
            channels: 3,
            height: index === 0 ? 2 : 4,
            width: index === 0 ? 2 : 4,
          },
        })
          .png()
          .toFile(path.join(root, `${name}.png`));
      })
    );
    writeFileSync(
      manifestPath,
      JSON.stringify({ ...manifest, appVersion: "0.8.0" })
    );
    await assert.rejects(
      importNativeCapture(root, "0.9.0", manifestPath),
      /this release's native frames/u
    );
    assert.equal(captureArchiveState(directory, "native"), "missing");

    writeFileSync(manifestPath, JSON.stringify(manifest));
    const metadata = await importNativeCapture(root, "0.9.0", manifestPath);
    assert.equal(metadata.appBuild, "42");
    assert.equal(metadata.source, "native");
    assert.equal(metadata.durationMs, 300);
    assert.equal(metadata.width, 4);
    assert.equal(metadata.height, 4);

    const image = await sharp(path.join(directory, "peek-native.webp"), {
      animated: true,
    }).metadata();

    assert.equal(image.pages, 2);
    assert.deepEqual(image.delay, [100, 200]);
    assert.equal(image.loop, 1);
    assert.equal(captureArchiveState(directory, "native"), "complete");
    await assert.rejects(
      importNativeCapture(root, "0.9.0", manifestPath),
      /RECAPTURE=1/u
    );

    const archive = readFileSync(path.join(directory, "capture.json"), "utf-8");
    writeFileSync(
      manifestPath,
      JSON.stringify({
        ...manifest,
        frames: [{ delay: 100, file: "../closed.png" }, manifest.frames[1]],
      })
    );
    await assert.rejects(
      importNativeCapture(root, "0.9.0", manifestPath, true)
    );
    assert.equal(
      readFileSync(path.join(directory, "capture.json"), "utf-8"),
      archive
    );
  } finally {
    rmSync(root, { force: true, recursive: true });
  }
});

test("capture provenance includes new sources and tolerates source deletion", () => {
  const root = mkdtempSync(path.join(tmpdir(), "lilo-capture-source-"));
  const source = path.join(root, "lilo-ui/src");
  const git = (...args: string[]) => execFileSync("git", args, { cwd: root });

  try {
    git("init", "--quiet");
    mkdirSync(source, { recursive: true });
    writeFileSync(path.join(source, "existing.ts"), "export const value = 1;");
    git("add", "lilo-ui/src/existing.ts");
    const original = captureSourceDigest(root);
    writeFileSync(path.join(source, "new.ts"), "export const added = 2;");
    const withNewFile = captureSourceDigest(root);
    assert.notEqual(withNewFile, original);
    git("add", "lilo-ui/src/new.ts");
    assert.equal(captureSourceDigest(root), withNewFile);
    unlinkSync(path.join(source, "existing.ts"));
    const afterDeletion = captureSourceDigest(root);
    assert.notEqual(afterDeletion, withNewFile);
    writeFileSync(path.join(root, ".gitignore"), "lilo-ui/src/ignored.ts\n");
    writeFileSync(path.join(source, "ignored.ts"), "ignored");
    assert.equal(captureSourceDigest(root), afterDeletion);
  } finally {
    rmSync(root, { force: true, recursive: true });
  }
});
