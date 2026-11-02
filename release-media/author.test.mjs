import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cp, mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { chooseMedia } from "./author.mjs";

const catalog = {
  releases: {
    "0.8.0": {
      kind: "video",
      feature: "tab-share",
      reason: "Demonstrate tab sharing.",
      notes: ["The tab share picker searches tabs by title."],
      alt: { en: "Find and share a tab.", fr: "Trouvez et partagez un onglet." },
    },
    "0.13.0": {
      kind: "screenshot",
      feature: "seasons",
      reason: "Show finished seasonal artwork.",
      notes: ["A seasonal icon dresses up for the holidays."],
      alt: { en: "Seasonal icons.", fr: "Les icônes de saison." },
    },
  },
};

test("a new tab-sharing release chooses its supported native movie and exact source note", () => {
  const note = "The tab share picker searches by title and previews the tabs before sharing.";
  const result = chooseMedia("0.15.0", `### Added\n\n- ${note}\n`, catalog);
  assert.equal(result.kind, "video");
  assert.equal(result.feature, "tab-share");
  assert.deepEqual(result.notes, [note]);
  assert.deepEqual(result.alt, catalog.releases["0.8.0"].alt);
});

test("finished artwork chooses a screenshot", () => {
  const result = chooseMedia(
    "0.15.0",
    "### Added\n\n- A seasonal icon dresses up for the holidays.\n",
    catalog,
  );
  assert.equal(result.kind, "screenshot");
});

test("fix-only releases and nonvisual API changes need no artificial media", () => {
  for (const notes of [
    "### Fixed\n\n- Closing a tab no longer logs an error.\n",
    "### Added\n\n- The agent API can send longer messages through its bridge.\n",
    "### Changed\n\n- Release highlights use HyperFrames videos and screenshots.\n",
    "### Changed\n\n- [release tooling] The release workflow renders HyperFrames videos.\n",
  ])
    assert.equal(chooseMedia("0.15.1", notes, catalog).kind, "none");
});

test("an unsupported new visual feature refuses the release instead of falling back", () => {
  for (const kind of ["Added", "Changed", "Breaking"])
    assert.throws(
      () =>
        chooseMedia(
          "0.15.0",
          `### ${kind}\n\n- A split view pane shows two pages side by side.\n`,
          catalog,
        ),
      /blocked.*no genuine native capture.*split view pane/,
    );
});

for (const kind of ["Added", "Changed", "Breaking"]) {
  for (const [description, note] of [
    ["memory", "A split view shows two documents side by side with lower memory use."],
    ["cache", "A preview pane shows documents fetched from the cache."],
    ["CPU", "A separate window compares two documents with lower CPU use."],
  ])
    test(`${kind} visual changes mentioning ${description} still require supported media`, () => {
      assert.throws(
        () => chooseMedia("0.15.0", `### ${kind}\n\n- ${note}\n`, catalog),
        /blocked.*no genuine native capture/,
      );
    });
}

test("nonvisual performance changes need no artificial media", () => {
  for (const kind of ["Added", "Changed", "Breaking"])
    for (const note of [
      "Audio processing uses less CPU.",
      "Audio processing uses less memory.",
      "The cache refreshes only after authentication changes.",
    ])
      assert.equal(chooseMedia("0.15.0", `### ${kind}\n\n- ${note}\n`, catalog).kind, "none");
});

for (const note of [
  "Opening a new window uses less CPU.",
  "Rendering a web page uses less memory.",
  "The sidebar consumes less memory.",
  "The preview pane requires fewer CPU cycles.",
])
  test(`routine Changed optimization stays text-only: ${note}`, () => {
    assert.equal(chooseMedia("0.15.0", `### Changed\n\n- ${note}\n`, catalog).kind, "none");
  });

test("explicit new interface changes cannot use the Changed optimization exemption", () => {
  for (const kind of ["Added", "Changed", "Breaking"])
    assert.throws(
      () => chooseMedia("0.15.0", `### ${kind}\n\n- A new preview pane uses less memory.\n`, catalog),
      /blocked.*no genuine native capture/,
    );
});

test("resource reductions do not hide an additional interface behavior", () => {
  for (const kind of ["Added", "Changed", "Breaking"])
    for (const note of [
      "A split view shows two documents and uses less memory.",
      "A preview pane shows cached documents. It uses less CPU.",
      "A separate window compares documents while consuming less memory.",
    ])
      assert.throws(
        () => chooseMedia("0.15.0", `### ${kind}\n\n- ${note}\n`, catalog),
        /blocked.*no genuine native capture/,
      );
});

test("a rendering-tool name cannot hide an unsupported product interface", () => {
  assert.throws(
    () =>
      chooseMedia(
        "0.15.0",
        "### Added\n\n- A new sidebar panel plays HyperFrames exports.\n",
        catalog,
      ),
    /blocked.*sidebar panel/,
  );
});

test("a supported important interaction is chosen from a larger release", () => {
  const result = chooseMedia(
    "0.15.0",
    "### Added\n\n- A seasonal icon dresses up for the holidays.\n- The tab share picker previews tabs.\n",
    catalog,
  );
  assert.equal(result.kind, "video");
  assert.deepEqual(result.notes, ["The tab share picker previews tabs."]);
});

test("a familiar feature cannot conceal an unsupported new visual feature", () => {
  for (const kind of ["Added", "Changed", "Breaking"])
    assert.throws(
      () =>
        chooseMedia(
          "0.15.0",
          `### Added\n\n- The tab share picker previews tabs.\n\n### ${kind}\n\n- A split view pane shows two pages side by side.\n`,
          catalog,
        ),
      /blocked.*split view pane/,
    );
});

test("new notes reconsider an automatically authored text-only or visual decision", () => {
  for (const original of [
    "### Fixed\n\n- Closing a tab no longer logs an error.\n",
    "### Added\n\n- The tab share picker previews tabs.\n",
  ]) {
    const decision = chooseMedia("0.15.0", original, catalog);
    assert.match(decision.notesSha256, /^[a-f0-9]{64}$/);
    const authored = { releases: { ...catalog.releases, "0.15.0": decision } };
    assert.throws(
      () =>
        chooseMedia(
          "0.15.0",
          original + "\n### Added\n\n- A split view pane shows two pages side by side.\n",
          authored,
        ),
      /blocked.*split view pane/,
    );
  }
  const fixes = "### Fixed\n\n- Closing a tab no longer logs an error.\n";
  const initial = chooseMedia("0.15.0", fixes, catalog);
  const updated = chooseMedia("0.15.0", "### Added\n\n- The tab share picker previews tabs.\n", {
    releases: { ...catalog.releases, "0.15.0": initial },
  });
  assert.equal(updated.kind, "video");
  assert.equal(updated.variant, "share");
  assert.notEqual(updated.notesSha256, initial.notesSha256);
});

test("existing editorial decisions keep their subject but must still match their notes", () => {
  const result = chooseMedia(
    "0.8.0",
    "### Changed\n\n- The tab share picker searches tabs by title.\n",
    catalog,
  );
  assert.equal(result.reason, catalog.releases["0.8.0"].reason);
  assert.throws(
    () => chooseMedia("0.8.0", "### Fixed\n\n- An unrelated fix.\n", catalog),
    /exact source notes/,
  );
});

test("invalid versions and missing canonical capabilities fail closed", () => {
  for (const version of ["", "main", "0.15", "../0.15.0"])
    assert.throws(() => chooseMedia(version, "", catalog), /Invalid release media version/);
  assert.throws(
    () =>
      chooseMedia("0.15.0", "### Added\n\n- The tab share picker previews tabs.\n", {
        releases: {},
      }),
    /Missing canonical native media recipe/,
  );
});

test("CI media queries are read-only and reject an unknown prepared version", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "lilo-media-author-"));
  try {
    await mkdir(path.join(root, "release-media"));
    await mkdir(path.join(root, ".changes"));
    for (const file of ["author.mjs", "pipeline.mjs", "fixtures.mjs"])
      await cp(
        fileURLToPath(new URL(file, import.meta.url)),
        path.join(root, "release-media", file),
      );
    const file = path.join(root, "release-media/backlog.json");
    const before = JSON.stringify(catalog);
    await writeFile(file, before);
    await writeFile(
      path.join(root, "CHANGELOG.md"),
      "## [0.8.0]\n\n### Changed\n\n- The tab share picker searches tabs by title.\n",
    );
    await writeFile(
      path.join(root, ".changes/v0.15.0.md"),
      "## [0.15.0]\n\n### Added\n\n- The tab share picker previews tabs.\n",
    );
    const query = (version, flag) =>
      spawnSync(
        process.execPath,
        [path.join(root, "release-media/author.mjs"), ...(flag ? [flag] : [])],
        {
          encoding: "utf8",
          env: {
            ...process.env,
            LILO_RELEASE_MEDIA_VERSION: version,
          },
        },
      );
    const result = query("0.15.0", "--fixture");
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "0.8.0\n");
    assert.equal(await readFile(file, "utf8"), before);
    await writeFile(
      path.join(root, ".changes/v0.15.1.md"),
      "## [0.15.1]\n\n### Fixed\n\n- A sleeping tab wakes correctly.\n",
    );
    const textOnly = query("0.15.1", "--fixture");
    assert.equal(textOnly.status, 0, textOnly.stderr);
    assert.equal(textOnly.stdout, "\n");
    assert.equal(await readFile(file, "utf8"), before);
    const missing = query("9.9.9", "--fixture");
    assert.notEqual(missing.status, 0);
    assert.match(missing.stderr, /Unknown release media version: 9.9.9/);
    assert.equal(await readFile(file, "utf8"), before);
    await writeFile(file, JSON.stringify({ ...catalog, publication: "blocked" }));
    const authored = query("0.15.0");
    assert.equal(authored.status, 0, authored.stderr);
    const after = JSON.parse(await readFile(file, "utf8"));
    assert.equal(
      after.publication,
      "blocked",
      "authoring must not re-enable a publication kill switch",
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
