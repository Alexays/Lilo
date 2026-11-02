import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

test("imports only verified receipt files and preserves the last import on a corrupt secondary source", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "lilo-native-import-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const version = "0.15.0";
  const media = path.join(root, "release-media");
  const source = path.join(root, "build/release-media/native", version);
  const target = path.join(media, "public/native", version);
  await mkdir(media);
  await mkdir(path.join(source, "detail"), { recursive: true });
  await mkdir(target, { recursive: true });
  for (const file of ["import.mjs", "pipeline.mjs", "fixtures.mjs"])
    await cp(fileURLToPath(new URL(file, import.meta.url)), path.join(media, file));
  await writeFile(
    path.join(media, "backlog.json"),
    JSON.stringify({ releases: { [version]: { kind: "screenshot", feature: "settings" } } }),
  );
  const expected = new Map();
  for (const [directory, file, bytes] of [
    ["", "primary.png", Buffer.from([1, 2, 3])],
    ["detail", "secondary.png", Buffer.from([4, 5, 6])],
  ]) {
    const receipt = Buffer.from(
      JSON.stringify({
        release: version,
        feature: "settings",
        appVersion: "0.15.0",
        appBuild: "1",
        productSourceCommit: "synthetic-source-commit",
        assets: [
          { file, width: 1, height: 1, sha256: createHash("sha256").update(bytes).digest("hex") },
        ],
      }),
    );
    for (const [name, data] of [
      [file, bytes],
      ["capture.json", receipt],
    ]) {
      const relative = path.join(directory, name);
      await writeFile(path.join(source, relative), data);
      expected.set(relative, data);
    }
  }
  for (const file of ["unlisted.png", "failure.json", "detail/unlisted.png"])
    await writeFile(path.join(source, file), "unlisted fixture");
  await writeFile(path.join(target, "stale.png"), "previous unused asset");
  const run = () =>
    spawnSync(process.execPath, [path.join(media, "import.mjs")], {
      encoding: "utf8",
      env: { ...process.env, LILO_RELEASE_MEDIA_VERSION: version },
    });
  const imported = run();
  assert.equal(imported.status, 0, imported.stderr);
  const files = [...expected.keys(), "detail"].sort();
  assert.deepEqual((await readdir(target, { recursive: true })).sort(), files);
  for (const [file, bytes] of expected)
    assert.deepEqual(await readFile(path.join(target, file)), bytes);

  await writeFile(path.join(source, "detail/secondary.png"), Buffer.from([9]));
  const rejected = run();
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /Native pixels changed/u);
  assert.deepEqual((await readdir(target, { recursive: true })).sort(), files);
  for (const [file, bytes] of expected)
    assert.deepEqual(await readFile(path.join(target, file)), bytes);
});
