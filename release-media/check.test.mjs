import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const json = (value) => JSON.stringify(value, null, 2) + "\n";

test("publication fails closed against the measured HyperFrames film and its sources", async (t) => {
  const scratch = await mkdtemp(path.join(tmpdir(), "lilo-publication-test-"));
  t.after(() => rm(scratch, { recursive: true, force: true }));
  const folder = path.join(scratch, "release-media");
  const version = "0.8.0";
  const backlog = JSON.parse(await readFile(path.join(root, "backlog.json"), "utf8"));
  const entry = backlog.releases[version];
  const catalog = {
    schemaVersion: 1,
    publication: "quality-gated",
    releases: { [version]: entry },
  };
  const assets = path.join(folder, "assets", version);
  await mkdir(path.join(folder, "public/native"), { recursive: true });
  await mkdir(path.join(folder, "hyperframes"), { recursive: true });
  await cp(path.join(root, "assets", version), assets, { recursive: true });
  await cp(path.join(root, "public/native", version), path.join(folder, "public/native", version), {
    recursive: true,
  });
  await cp(
    path.join(root, "hyperframes", version),
    path.join(folder, "hyperframes", version),
    {
      recursive: true,
    },
  );
  await cp(path.join(root, "public/audio"), path.join(folder, "public/audio"), { recursive: true });
  for (const file of ["check.mjs", "pipeline.mjs", "fixtures.mjs"])
    await cp(path.join(root, file), path.join(folder, file));
  for (const file of [
    "render.mjs",
    "png-cutouts.mjs",
    "package-lock.json",
    "hyperframes/assets",
  ])
    await cp(path.join(root, file), path.join(folder, file), { recursive: true });
  await writeFile(path.join(folder, "backlog.json"), json(catalog));
  await writeFile(
    path.join(scratch, "CHANGELOG.md"),
    `## [${version}]\n${entry.notes.join("\n")}\n`,
  );
  const run = (environment = {}) =>
    execFileSync(process.execPath, [path.join(folder, "check.mjs"), "--publish"], {
      env: { PATH: "", ...environment },
      stdio: "pipe",
    }).toString();
  const renderFile = path.join(assets, "render.json");
  const qualityFile = path.join(assets, "quality.json");
  const render = JSON.parse(await readFile(renderFile, "utf8"));
  const expectQualityFailure = /needs a passing quality check for these exact bytes/u;
  async function withChangedFile(file, change, check) {
    const original = await readFile(file);
    try {
      await writeFile(file, await change(original));
      await check();
    } finally {
      await writeFile(file, original);
    }
  }
  const rejectJson = (name, file, change, message = expectQualityFailure) =>
    t.test(name, () =>
      withChangedFile(
        file,
        (bytes) => {
          const value = JSON.parse(bytes);
          change(value);
          return json(value);
        },
        () => assert.throws(run, message),
      ),
    );

  await t.test("publishes the measured film using Node alone", () => {
    assert.equal(render.engine, "hyperframes");
    assert.match(run(), /Quality-gated 0\.8\.0: video tab-share/u);
  });
  await t.test("an unrelated fixture preserves publication of the measured film", () =>
    withChangedFile(
      path.join(folder, "fixtures.mjs"),
      (bytes) => Buffer.concat([bytes, Buffer.from('\nfixtures["unrelated"] = "99.0.0";\n')]),
      () => assert.match(run(), /Quality-gated 0\.8\.0: video tab-share/u),
    ),
  );
  await t.test("soundtrack documentation does not invalidate the measured film", () =>
    withChangedFile(
      path.join(folder, "public/audio/music.README.md"),
      (bytes) => Buffer.concat([bytes, Buffer.from("\nClarified soundtrack documentation.\n")]),
      () => assert.match(run(), /Quality-gated 0\.8\.0: video tab-share/u),
    ),
  );
  await t.test("a changed selected fixture refuses the measured film", () =>
    withChangedFile(
      path.join(folder, "fixtures.mjs"),
      (bytes) => bytes.toString().replace('"tab-share": "0.8.0"', '"tab-share": "0.10.0"'),
      () => assert.throws(run, /HyperFrames recipe changed/u),
    ),
  );
  await rejectJson(
    "a disabled publication policy blocks the release",
    path.join(folder, "backlog.json"),
    (value) => {
      value.publication = "blocked";
    },
    /media publication is disabled/u,
  );
  await t.test("a missing quality receipt blocks the release", async () => {
    const original = await readFile(qualityFile);
    try {
      await rm(qualityFile);
      assert.throws(run, /quality\.json/u);
    } finally {
      await writeFile(qualityFile, original);
    }
  });
  await rejectJson("a stale quality receipt is refused", qualityFile, (q) => {
    q.renderSha256 = "stale";
  });
  await rejectJson("a failed quality receipt is refused", qualityFile, (q) => {
    q.passed = false;
  });
  for (const flag of [
    "sourceHashes",
    "renderHashes",
    "cutoutsVerified",
    "strictCompositionCheck",
    "decode",
  ])
    await rejectJson(`missing ${flag} verification blocks publication`, qualityFile, (q) => {
      q[flag] = false;
    });
  for (const [name, field, value] of [
    ["insufficient measured frames", "measuredFrames", 0],
    ["too little motion", "movingFrameRatio", 0],
    ["a long static hold", "longestStillSeconds", 3.1],
    ["a large frame jump", "largestLumaChange", 91],
  ])
    await rejectJson(name, qualityFile, (q) => {
      q.motion[field] = value;
    });
  await rejectJson("a blurry encoded poster is refused", qualityFile, (q) => {
    q.posterSSIM = 0.97;
  });
  for (const [name, field, value] of [
    ["quiet audio", "integratedLoudnessLUFS", -30],
    ["loud audio", "integratedLoudnessLUFS", -5],
    ["clipping audio", "truePeakDbFS", 0],
  ])
    await rejectJson(name, qualityFile, (q) => {
      q.audio[field] = value;
    });
  const licenseFile = path.join(folder, "public/audio/music.license.json");
  await t.test("a soundtrack requiring attribution is refused", () =>
    withChangedFile(
      licenseFile,
      (bytes) => {
        const license = JSON.parse(bytes);
        license.attributionRequired = true;
        return json(license);
      },
      async () => {
        const licenseHash = createHash("sha256")
          .update(await readFile(licenseFile))
          .digest("hex");
        await withChangedFile(
          renderFile,
          (bytes) => {
            const value = JSON.parse(bytes);
            value.recipeHashes["public/audio/music.license.json"] = licenseHash;
            return json(value);
          },
          () =>
            withChangedFile(
              qualityFile,
              async (bytes) => {
                const quality = JSON.parse(bytes);
                quality.renderSha256 = createHash("sha256")
                  .update(await readFile(renderFile))
                  .digest("hex");
                return json(quality);
              },
              () => assert.throws(run, /soundtrack must not require attribution/u),
            ),
        );
      },
    ),
  );
  await rejectJson(
    "a previous recipe schema cannot be published",
    renderFile,
    (value) => {
      value.schemaVersion = 2;
    },
    /Stale HyperFrames render/u,
  );
  await rejectJson(
    "a previous rendering engine cannot be published",
    renderFile,
    (value) => {
      value.engine = "remotion";
    },
    /Stale HyperFrames render/u,
  );
  for (const [name, change] of [
    [
      "an omitted poster digest",
      (value) => {
        delete value.hashes["tab-share.png"];
      },
    ],
    [
      "an omitted film digest",
      (value) => {
        delete value.hashes["tab-share.mp4"];
      },
    ],
    [
      "an empty digest map",
      (value) => {
        value.hashes = {};
      },
    ],
    [
      "an invalid digest",
      (value) => {
        value.hashes["tab-share.mp4"] = "invalid";
      },
    ],
  ])
    await t.test(`${name} is refused even with a matching quality receipt`, async () => {
      const changed = structuredClone(render);
      change(changed);
      const bytes = json(changed);
      await withChangedFile(
        renderFile,
        () => bytes,
        () =>
          withChangedFile(
            qualityFile,
            (original) => {
              const quality = JSON.parse(original);
              quality.renderSha256 = createHash("sha256").update(bytes).digest("hex");
              return json(quality);
            },
            () => assert.throws(run, /Missing or invalid rendered hashes/u),
          ),
      );
    });
  await t.test("changed encoded bytes are refused", () =>
    withChangedFile(
      path.join(assets, "tab-share.mp4"),
      () => "changed encoded bytes",
      () => assert.throws(run, /Rendered media changed/u),
    ),
  );
  await rejectJson(
    "changed native provenance is refused",
    path.join(folder, "public/native", version, "capture.json"),
    (value) => {
      value.productSourceCommit = "different-build";
    },
    /Native receipt changed/u,
  );
  await t.test("changed native pixels are refused", () =>
    withChangedFile(
      path.join(folder, render.cutouts[0].source),
      (bytes) => Buffer.concat([bytes, Buffer.from("changed native pixels")]),
      () => assert.throws(run, /Native pixels changed/u),
    ),
  );
  await t.test("changed composition code invalidates the render", () =>
    withChangedFile(
      path.join(folder, "hyperframes", version, "index.html"),
      (bytes) => Buffer.concat([bytes, Buffer.from("\n<!-- changed composition -->\n")]),
      () => assert.throws(run, /HyperFrames recipe changed/u),
    ),
  );
  await t.test("a changed selected scene invalidates the render", () =>
    withChangedFile(
      path.join(folder, "hyperframes", version, "compositions/find.html"),
      (bytes) => Buffer.concat([bytes, Buffer.from("\n<!-- changed selected scene -->\n")]),
      () => assert.throws(run, /HyperFrames recipe changed/u),
    ),
  );
  await t.test("an unrelated composition does not invalidate the render", async () => {
    const unrelated = path.join(folder, "hyperframes/99.0.0");
    await mkdir(unrelated);
    await writeFile(path.join(unrelated, "index.html"), "Unrelated composition");
    assert.match(run(), /Quality-gated 0\.8\.0: video tab-share/u);
  });
  for (const file of ["render.mjs", "public/audio/music.ogg", "public/audio/mouse-click.wav"])
    await t.test(`changing ${file} invalidates the film`, () =>
      withChangedFile(
        path.join(folder, file),
        (bytes) => Buffer.concat([bytes, Buffer.from("\nchanged input\n")]),
        () => assert.throws(run, /HyperFrames recipe changed/u),
      ),
    );
  await t.test("changing the ending invalidates the selected film", () =>
    withChangedFile(
      path.join(folder, "hyperframes", version, "compositions/end.html"),
      (bytes) => Buffer.concat([bytes, Buffer.from("\n<!-- changed shared ending -->\n")]),
      () => assert.throws(run, /HyperFrames recipe changed/u),
    ),
  );
  await t.test("a tag must use captures from its exact source commit", () => {
    const source = render.nativeReceipts[0].productSourceCommit;
    const selectedTag = { GITHUB_REF_TYPE: "tag", LILO_RELEASE_MEDIA_VERSION: version };
    assert.throws(() => run({ ...selectedTag, GITHUB_SHA: source }), /app version/u);
    assert.throws(
      () => run({ ...selectedTag, GITHUB_SHA: "different-tag-commit" }),
      /native capture is not from this tag/u,
    );
  });
  await t.test("unselected publication retains verified captures", () => {
    assert.match(
      run({ GITHUB_REF_TYPE: "tag", GITHUB_SHA: "new-release-commit" }),
      /Quality-gated 0\.8\.0/u,
    );
  });
  await t.test("restoring the verified inputs makes publication pass again", () => {
    assert.match(run(), /Quality-gated 0\.8\.0: video tab-share/u);
  });
});
