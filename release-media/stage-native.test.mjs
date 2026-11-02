import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

async function staging(t, releases) {
  const root = await mkdtemp(path.join(tmpdir(), "lilo-native-staging-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const media = path.join(root, "release-media");
  const ui = path.join(root, "lilo-ui");
  const target = path.join(ui, "public/release-media");
  await mkdir(media);
  await mkdir(target, { recursive: true });
  await cp(
    fileURLToPath(new URL("./stage-native.mjs", import.meta.url)),
    path.join(media, "stage-native.mjs"),
  );
  await writeFile(path.join(ui, "package.json"), JSON.stringify({ version: "0.14.1" }));
  await writeFile(path.join(media, "backlog.json"), JSON.stringify({ releases }));
  await writeFile(path.join(target, ".gitkeep"), "");
  await writeFile(path.join(target, "stale.mp4"), "old release");
  const run = (version = "") =>
    spawnSync(process.execPath, [path.join(media, "stage-native.mjs")], {
      encoding: "utf8",
      env: { ...process.env, LILO_RELEASE_MEDIA_PREVIEW_VERSION: version },
    });
  return { media, target, run };
}

test("a release without media clears stale assets and keeps its placeholder", async (t) => {
  for (const releases of [{}, { "0.14.1": { kind: "none" } }]) {
    const { target, run } = await staging(t, releases);
    const result = run();
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(await readdir(target), [".gitkeep"]);
  }
});

test("previewing a film requires both assets and stages only that release", async (t) => {
  const version = "0.8.0";
  const { media, target, run } = await staging(t, {
    [version]: { kind: "video", feature: "tab-share" },
  });
  const missing = run(version);
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /ENOENT/);
  const source = path.join(media, "assets", version);
  await mkdir(source, { recursive: true });
  await writeFile(path.join(source, "tab-share.png"), "approved poster");
  await writeFile(path.join(source, "tab-share.mp4"), "approved film");
  await writeFile(path.join(source, "render.json"), "authoring metadata");
  const result = run(version);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual((await readdir(target)).sort(), [".gitkeep", version]);
  assert.deepEqual((await readdir(path.join(target, version))).sort(), ["tab-share.mp4", "tab-share.png"]);
  assert.equal(await readFile(path.join(target, version, "tab-share.png"), "utf8"), "approved poster");
  assert.equal(await readFile(path.join(target, version, "tab-share.mp4"), "utf8"), "approved film");
  assert.equal(run(version).status, 0);
  assert.equal(run().status, 0);
  assert.deepEqual(await readdir(target), [".gitkeep"]);
});

test("a screenshot stages its poster without requiring a film", async (t) => {
  const version = "0.15.0";
  const { media, target, run } = await staging(t, {
    [version]: { kind: "screenshot", feature: "browser" },
  });
  const source = path.join(media, "assets", version);
  await mkdir(source, { recursive: true });
  await writeFile(path.join(source, "browser.png"), "approved still");
  const result = run(version);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(await readdir(path.join(target, version)), ["browser.png"]);
});
