import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import type {
  AuthoredArchive,
  ReleaseIdentity,
} from "../captures/authored-archive.ts";
import {
  artifactDigest,
  checkPreparedRelease,
  releaseIdentity,
} from "../captures/authored-archive.ts";
import { checkPublication } from "../captures/publication.ts";
import { fileDigest } from "../captures/remotion/presentation.ts";

const maintenanceArchive = (identity: ReleaseIdentity): AuthoredArchive => {
  const archive: AuthoredArchive = {
    appBuild: identity.build,
    approval: {
      digest: "",
      passed: true,
      reviews: {
        content: { passed: true, problems: [] },
        selection: { passed: true, problems: [] },
      },
    },
    content: Object.fromEntries(
      identity.locales.map((locale) => [
        locale,
        {
          description: "Reliability improvements.",
          headline: "A little steadier.",
          highlights: [],
        },
      ])
    ),
    inputDigest: identity.inputDigest,
    plan: {
      decisions: identity.notes.map((note) => ({
        mode: "text",
        note,
        reason:
          "Internal storage reliability has no honest visual demonstration.",
      })),
      description: "Reliability improvements.",
      headline: "A little steadier.",
      highlights: [],
      noMediaReason: "Only internal reliability work changed in this release.",
      version: identity.version,
    },
    recordings: {},
    release: identity.version,
    scenarioDigests: {},
    schemaVersion: 3,
    source: "native",
  };

  archive.approval.digest = artifactDigest(archive);

  return archive;
};

const save = (file: string, value: string) => {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, value);
};

test("website publication requires a current approved decision and checks historical archive integrity", () => {
  const root = mkdtempSync(path.join(tmpdir(), "lilo-publish-"));

  try {
    execFileSync("git", ["init", "--quiet", root]);
    save(path.join(root, "lilo-ui/package.json"), '{"version":"0.9.0"}');
    save(
      path.join(root, "Xcode/Configs/Base.xcconfig"),
      "MARKETING_VERSION = 0.9.0\nCURRENT_PROJECT_VERSION = 42\n"
    );

    for (const locale of ["en", "fr"]) {
      save(
        path.join(root, `lilo-ui/src/lib/i18n/locales/${locale}.json`),
        "{}"
      );
    }

    const notes =
      "## [0.9.0] - 2026-10-29\n\n### Fixed\n\n- Improves background storage.\n";

    save(path.join(root, "CHANGELOG.md"), notes);
    save(path.join(root, ".changes/v0.9.0.md"), notes);
    const identity = releaseIdentity(root, "0.9.0");
    const current = path.join(root, "site/src/assets/releases/0.9.0");
    save(
      path.join(current, "capture.json"),
      JSON.stringify(maintenanceArchive(identity))
    );

    const historical = maintenanceArchive({
      ...identity,
      build: "41",
      inputDigest: "b".repeat(64),
      version: "0.8.0",
    });

    const historicalFile = path.join(
      root,
      "site/src/assets/releases/0.8.0/capture.json"
    );

    save(historicalFile, JSON.stringify(historical));
    assert.doesNotThrow(() => checkPublication(root));

    const presentation = {
      approved: false,
      media: {},
      release: "0.9.0",
      schemaVersion: 1,
      sourceArchiveDigest: fileDigest(
        readFileSync(path.join(current, "capture.json"))
      ),
    };

    save(path.join(current, "presentation.json"), JSON.stringify(presentation));
    assert.throws(() => checkPublication(root), /awaiting visual approval/u);
    assert.throws(
      () => checkPreparedRelease(current, identity),
      /awaiting visual approval/u
    );
    presentation.approved = true;
    save(path.join(current, "presentation.json"), JSON.stringify(presentation));
    assert.doesNotThrow(() => checkPublication(root));
    historical.content.fr.headline = "Unapproved text";
    save(historicalFile, JSON.stringify(historical));
    assert.throws(() => checkPublication(root), /modified|approval/u);
    historical.content.fr.headline = "A little steadier.";
    save(historicalFile, JSON.stringify(historical));
    renameSync(current, `${current}.parked`);
    assert.throws(() => checkPublication(root), /ENOENT|missing/u);
    renameSync(`${current}.parked`, current);
    save(
      path.join(root, "Xcode/Configs/Base.xcconfig"),
      "MARKETING_VERSION = 0.9.0\nCURRENT_PROJECT_VERSION = 42\n// New source\n"
    );
    assert.throws(() => checkPublication(root), /source|input/u);
  } finally {
    rmSync(root, { force: true, recursive: true });
  }
});

test("the website deploy command verifies media while ordinary builds stay offline", () => {
  const { scripts } = JSON.parse(
    readFileSync(new URL("../package.json", import.meta.url), "utf-8")
  );

  assert.match(scripts.deploy, /^node captures\/publication\.ts && /u);
  assert.doesNotMatch(scripts.build, /publication|produce-native/u);
});
