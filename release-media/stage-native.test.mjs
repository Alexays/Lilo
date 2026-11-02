import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

test("capture hosts omit media that does not exist yet; normal builds require and stage it", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "lilo-native-staging-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const media = path.join(root, "release-media");
  const ui = path.join(root, "lilo-ui");
  const target = path.join(ui, "public/release-media");
  const version = "0.15.0";
  await mkdir(media);
  await mkdir(target, { recursive: true });
  await cp(
    fileURLToPath(new URL("./stage-native.mjs", import.meta.url)),
    path.join(media, "stage-native.mjs"),
  );
  await writeFile(path.join(ui, "package.json"), JSON.stringify({ version }));
  await writeFile(
    path.join(media, "backlog.json"),
    JSON.stringify({ releases: { [version]: { kind: "video", feature: "tab-share" } } }),
  );
  await writeFile(path.join(target, ".gitkeep"), "");
  await writeFile(path.join(target, "stale.mp4"), "old release");
  const run = (capturing = false) =>
    spawnSync(process.execPath, [path.join(media, "stage-native.mjs")], {
      encoding: "utf8",
      env: {
        ...process.env,
        LILO_RELEASE_MEDIA_CAPTURE_ONLY: capturing ? "1" : "",
        LILO_RELEASE_MEDIA_PREVIEW_VERSION: "",
      },
    });
  const capture = run(true);
  assert.equal(capture.status, 0, capture.stderr);
  assert.deepEqual(await readdir(target), [".gitkeep"]);
  const missing = run();
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /ENOENT/);
  const source = path.join(media, "assets", version);
  await mkdir(source, { recursive: true });
  await writeFile(path.join(source, "tab-share.png"), "verified poster");
  await writeFile(path.join(source, "tab-share.mp4"), "verified film");
  const normal = run();
  assert.equal(normal.status, 0, normal.stderr);
  assert.equal(
    await readFile(path.join(target, version, "tab-share.png"), "utf8"),
    "verified poster",
  );
  assert.equal(
    await readFile(path.join(target, version, "tab-share.mp4"), "utf8"),
    "verified film",
  );
});
