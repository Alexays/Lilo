import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
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
  const version = "0.11.0";
  const backlog = JSON.parse(await readFile(path.join(root, "backlog.json"), "utf8"));
  const entry = backlog.releases[version];
  const catalog = {
    schemaVersion: 1,
    publication: "quality-gated",
    releases: { [version]: entry },
  };
  const assets = path.join(folder, "assets", version);
  await mkdir(path.join(folder, "public/native"), { recursive: true });
  await mkdir(path.join(folder, "hyperframes/archive"), { recursive: true });
  await cp(path.join(root, "assets", version), assets, { recursive: true });
  await cp(path.join(root, "public/native", version), path.join(folder, "public/native", version), {
    recursive: true,
  });
  await cp(
    path.join(root, "hyperframes/archive", version),
    path.join(folder, "hyperframes/archive", version),
    {
      recursive: true,
    },
  );
  for (const file of ["check.mjs", "pipeline.mjs"])
    await cp(path.join(root, file), path.join(folder, file));
  for (const file of [
    "render.mjs",
    "png-cutouts.mjs",
    "package-lock.json",
    "public/audio",
    "hyperframes/assets",
    "hyperframes/archive/ending.html",
    "hyperframes/archive/shared.css",
    "hyperframes/archive/shared.js",
  ])
    await symlink(path.join(root, file), path.join(folder, file));
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
    assert.match(run(), /Quality-gated 0\.11\.0: video spaces/u);
  });
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
    ["a large frame jump", "largestLumaChange", 46],
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
  await rejectJson(
    "a soundtrack requiring attribution is refused",
    renderFile,
    (value) => {
      value.music.attributionRequired = true;
    },
    /soundtrack must not require attribution/u,
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
        delete value.hashes["spaces.png"];
      },
    ],
    [
      "an omitted film digest",
      (value) => {
        delete value.hashes["spaces.mp4"];
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
        value.hashes["spaces.mp4"] = "invalid";
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
      path.join(assets, "spaces.mp4"),
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
      path.join(folder, "hyperframes/archive", version, "index.html"),
      (bytes) => Buffer.concat([bytes, Buffer.from("\n<!-- changed composition -->\n")]),
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
  await t.test("publishing the archive retains verified historical captures", () => {
    assert.match(
      run({ GITHUB_REF_TYPE: "tag", GITHUB_SHA: "new-release-commit" }),
      /Quality-gated 0\.11\.0/u,
    );
  });
  await t.test("restoring the verified inputs makes publication pass again", () => {
    assert.match(run(), /Quality-gated 0\.11\.0: video spaces/u);
  });
});
