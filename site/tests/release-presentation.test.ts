import assert from "node:assert/strict";
import {
  copyFileSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import {
  checkPresentation,
  presentationSchema,
} from "../captures/remotion/presentation.ts";

const directory = new URL("../src/assets/releases/0.8.0/", import.meta.url);

test("0.8.0 uses a native still for audio and a native hybrid movie for tab sharing", () => {
  const presentation = checkPresentation(directory);
  assert.equal(presentation.release, "0.8.0");
  assert.equal(presentation.media["share-system-audio"].kind, "image");
  assert.equal(presentation.media["tab-sharing-controls"].kind, "video");
  assert.throws(
    () => checkPresentation(directory, { publication: true }),
    /awaiting visual approval/iu
  );
});

test("a presentation never substitutes a still for a broken movie or escapes its directory", () => {
  const value = JSON.parse(
    readFileSync(new URL("presentation.json", directory), "utf-8")
  );

  const missing = structuredClone(value);
  delete missing.media["tab-sharing-controls"].recording;
  assert.equal(presentationSchema.safeParse(missing).success, false);
  const traversal = structuredClone(value);
  traversal.media["share-system-audio"].poster = "../private.png";
  assert.equal(presentationSchema.safeParse(traversal).success, false);
});

test("missing, altered or different-release source and output block validation", async () => {
  const temporary = mkdtempSync(path.join(tmpdir(), "lilo-presentation-"));

  try {
    const value = JSON.parse(
      readFileSync(new URL("presentation.json", directory), "utf-8")
    );

    writeFileSync(
      path.join(temporary, "presentation.json"),
      JSON.stringify(value)
    );
    assert.throws(() => checkPresentation(temporary), /native source/iu);
    writeFileSync(path.join(temporary, "capture.json"), "{}");
    assert.throws(() => checkPresentation(temporary), /native source/iu);
    writeFileSync(
      path.join(temporary, "capture.json"),
      readFileSync(new URL("capture.json", directory))
    );
    assert.throws(
      () => checkPresentation(temporary),
      /missing presentation asset/iu
    );

    for (const media of Object.values(presentationSchema.parse(value).media)) {
      for (const name of [
        media.poster,
        ...(media.kind === "video" ? [media.recording] : []),
      ]) {
        copyFileSync(new URL(name, directory), path.join(temporary, name));
      }
    }

    assert.doesNotThrow(() => checkPresentation(temporary));
    writeFileSync(
      path.join(temporary, value.media["tab-sharing-controls"].recording),
      "changed"
    );
    assert.throws(
      () => checkPresentation(temporary),
      /changed presentation asset/iu
    );

    const source = JSON.parse(
      readFileSync(new URL("capture.json", directory), "utf-8")
    );

    source.release = "0.7.0";
    writeFileSync(path.join(temporary, "capture.json"), JSON.stringify(source));
    const { fileDigest } = await import("../captures/remotion/presentation.ts");
    value.sourceArchiveDigest = fileDigest(
      readFileSync(path.join(temporary, "capture.json"))
    );
    writeFileSync(
      path.join(temporary, "presentation.json"),
      JSON.stringify(value)
    );
    assert.throws(() => checkPresentation(temporary), /release mismatch/iu);
  } finally {
    rmSync(temporary, { recursive: true });
  }
});
