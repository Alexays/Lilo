import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import sharp from "sharp";

import type { AuthoredArchive } from "../captures/authored-archive.ts";
import {
  artifactDigest,
  checkAuthoredArchive,
  publishAuthoredArchive,
} from "../captures/authored-archive.ts";
import type {
  AuthoredScenario,
  Selection,
} from "../captures/authored-model.ts";
import { digest, encodeNativeProof } from "../captures/native-proof.ts";
import { storyFromArchive } from "../src/lib/authored-story.ts";
import { parseReleaseStories } from "../src/lib/release-stories.ts";

const identity = {
  build: "42",
  inputDigest: "a".repeat(64),
  locales: ["en", "fr"],
  notes: ["Tabs show unread counts."],
  version: "0.9.0",
};

const plan: Selection = {
  decisions: [
    {
      mode: "capture",
      note: identity.notes[0],
      reason: "The visible unread badge is the main improvement.",
    },
  ],
  description: "Keep up with your tabs.",
  headline: "Catch up.",
  highlights: [
    {
      description: "See unread counts.",
      id: "unread-counts",
      notes: identity.notes,
      reason: "This is a visible change used while browsing every day.",
      title: "Catch up.",
    },
  ],
  noMediaReason: "",
  version: identity.version,
};

const copy = {
  description: "Keep up with your tabs.",
  headline: "Catch up.",
  highlights: [
    {
      description: "See unread counts.",
      id: "unread-counts",
      title: "Catch up.",
    },
  ],
};

const recipe: AuthoredScenario = {
  evidence: ["Lilo/Window/MainWindowController.swift"],
  fixtures: [
    {
      html: "<!doctype html><title>Studio</title><h1>Inbox</h1>",
      name: "inbox.html",
    },
  ],
  goal: "Show the real native unread badge and its cleared state.",
  id: "unread-counts",
  posterCheckpoint: "badge-shown",
  settings: [],
  steps: [
    { durationMs: 600, type: "hold" },
    {
      id: "badge-shown",
      predicate: {
        kind: "visible",
        target: { selector: ".unread-badge", surface: "chrome", text: "" },
      },
      type: "assert",
    },
    { durationMs: 2100, type: "hold" },
    {
      id: "badge-cleared",
      predicate: {
        kind: "absent",
        target: { selector: ".unread-badge", surface: "chrome", text: "" },
      },
      type: "assert",
    },
    { durationMs: 2100, type: "hold" },
  ],
  tabs: [{ id: "inbox", page: "inbox.html" }],
};

test("new-feature archives bind recipe bytes, translated content, native media and every required review", async () => {
  const root = mkdtempSync(path.join(tmpdir(), "authored-archive-"));
  const out = path.join(root, "approved");

  try {
    const directory = path.join(root, "unread-counts");
    mkdirSync(directory);
    const bytes = `${JSON.stringify(recipe)}\n`;

    const frames = Array.from({ length: 180 }, (_, i) => ({
      atMs: i * 33,
      file: `frame-${String(i).padStart(4, "0")}.png`,
    }));

    await Promise.all(
      frames.map(async (frame, i) => {
        const image = await sharp(
          Buffer.from(
            `<svg width="32" height="24"><rect width="32" height="24" fill="rgb(${i * 2},110,70)"/><rect width="12" height="24" fill="white"/></svg>`
          )
        )
          .png()
          .toBuffer();

        writeFileSync(path.join(directory, frame.file), image);
      })
    );

    const manifest = {
      appBuild: "42",
      appVersion: "0.9.0",
      captureTool: "ScreenCaptureKit.currentProcess",
      capturedAt: "2026-10-29T12:00:00Z",
      checkpoints: [
        { atMs: 1000, name: "badge-shown", passed: true },
        { atMs: 3900, name: "badge-cleared", passed: true },
      ],
      durationMs: 6000,
      frames,
      height: 24,
      inputDigest: identity.inputDigest,
      scenario: "unread-counts",
      scenarioDigest: digest(bytes),
      source: "native",
      width: 32,
    };

    writeFileSync(
      path.join(directory, "manifest.json"),
      JSON.stringify(manifest)
    );

    const recordings = await encodeNativeProof(
      root,
      out,
      "0.9.0",
      false,
      identity.inputDigest,
      [
        {
          checkpoints: ["badge-shown", "badge-cleared"],
          id: "unread-counts",
          posterCheckpoint: "badge-shown",
          scenarioDigest: digest(bytes),
        },
      ]
    );

    writeFileSync(path.join(out, "unread-counts-scenario.json"), bytes);

    const archive: AuthoredArchive = {
      appBuild: "42",
      approval: {
        digest: "",
        passed: true,
        reviews: Object.fromEntries(
          [
            "selection",
            "content",
            "author:unread-counts",
            "visual:unread-counts",
          ].map((key) => [key, { passed: true, problems: [] }])
        ),
      },
      content: { en: structuredClone(copy), fr: structuredClone(copy) },
      inputDigest: identity.inputDigest,
      plan,
      recordings,
      release: "0.9.0",
      scenarioDigests: { "unread-counts": digest(bytes) },
      schemaVersion: 3,
      source: "native",
    };

    archive.approval.digest = artifactDigest(archive);

    const save = () =>
      writeFileSync(path.join(out, "capture.json"), JSON.stringify(archive));

    save();
    assert.equal(checkAuthoredArchive(out, identity).release, "0.9.0");
    const story = storyFromArchive(checkAuthoredArchive(out, identity));

    const stories = parseReleaseStories(
      "## [0.9.0] - 2026-10-29\n\n### Added\n\n- Tabs show unread counts.\n",
      [story]
    );

    assert.equal(
      stories.get("0.9.0")?.highlights[0].capture?.scenario,
      "unread-counts"
    );
    archive.content.fr.headline = "Altered copy";
    save();
    assert.throws(
      () => checkAuthoredArchive(out, identity),
      /approval|modified/u
    );
    archive.content.fr.headline = copy.headline;
    save();
    writeFileSync(path.join(out, "unread-counts-scenario.json"), `${bytes} `);
    assert.throws(() => checkAuthoredArchive(out, identity), /scenario/u);
    writeFileSync(path.join(out, "unread-counts-scenario.json"), bytes);
    archive.approval.reviews["visual:unread-counts"].passed = false;
    save();
    assert.throws(() => checkAuthoredArchive(out, identity), /quality|review/u);
  } finally {
    rmSync(root, { force: true, recursive: true });
  }
});

test("unapproved maintenance and failed final publication preserve the previous archive", () => {
  const root = mkdtempSync(path.join(tmpdir(), "authored-maintenance-"));
  const stage = path.join(root, "stage");
  const out = path.join(root, "archive");

  try {
    mkdirSync(stage);
    mkdirSync(out);
    writeFileSync(path.join(out, "original"), "previous approved release");

    const maintenanceIdentity = {
      ...identity,
      notes: ["Improves background storage."],
    };

    const maintenance: Selection = {
      ...plan,
      decisions: [
        {
          mode: "text",
          note: maintenanceIdentity.notes[0],
          reason: "Storage reliability changes have no visible demonstration.",
        },
      ],
      highlights: [],
      noMediaReason: "Only internal maintenance changed in this release.",
    };

    const archive: AuthoredArchive = {
      appBuild: "42",
      approval: {
        digest: "",
        passed: true,
        reviews: { content: { passed: true, problems: [] } },
      },
      content: {
        en: { ...copy, highlights: [] },
        fr: { ...copy, highlights: [] },
      },
      inputDigest: identity.inputDigest,
      plan: maintenance,
      recordings: {},
      release: "0.9.0",
      scenarioDigests: {},
      schemaVersion: 3,
      source: "native",
    };

    archive.approval.digest = artifactDigest(archive);

    const save = () =>
      writeFileSync(path.join(stage, "capture.json"), JSON.stringify(archive));

    save();
    assert.throws(
      () => publishAuthoredArchive(stage, out, maintenanceIdentity),
      /review|quality/u
    );
    assert.equal(
      readFileSync(path.join(out, "original"), "utf-8"),
      "previous approved release"
    );
    Object.assign(archive.approval.reviews, {
      selection: { passed: true, problems: [] },
    });
    save();
    assert.equal(
      checkAuthoredArchive(stage, maintenanceIdentity).plan.highlights.length,
      0
    );

    const story = storyFromArchive(
      checkAuthoredArchive(stage, maintenanceIdentity)
    );

    assert.ok(story, "Approved maintenance copy stays visible without a movie");
    assert.deepEqual(story.title, { en: copy.headline, fr: copy.headline });
    assert.deepEqual(story.highlights, []);
    assert.equal(
      parseReleaseStories(
        "## [0.9.0] - 2026-10-29\n\n### Fixed\n\n- Improves background storage.\n",
        [story]
      ).get("0.9.0")?.title.en,
      copy.headline
    );
  } finally {
    rmSync(root, { force: true, recursive: true });
  }
});
