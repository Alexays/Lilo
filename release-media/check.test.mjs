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

test("publication requires approval and a passing receipt for the exact native film", async (t) => {
  const scratch = await mkdtemp(path.join(tmpdir(), "lilo-publication-test-"));
  t.after(() => rm(scratch, { recursive: true, force: true }));
  const folder = path.join(scratch, "release-media");
  const version = "0.11.0";
  const backlog = JSON.parse(await readFile(path.join(root, "backlog.json"), "utf8"));
  const catalog = { publication: "blocked", releases: { [version]: backlog.releases[version] } };
  const assets = path.join(folder, "assets", version);
  await mkdir(path.join(folder, "public/native"), { recursive: true });
  await cp(path.join(root, "assets", version), assets, { recursive: true });
  await cp(path.join(root, "check.mjs"), path.join(folder, "check.mjs"));
  await symlink(
    path.join(root, "public/native", version),
    path.join(folder, "public/native", version),
  );
  await symlink(path.join(root, "src"), path.join(folder, "src"));
  await symlink(path.join(root, "package-lock.json"), path.join(folder, "package-lock.json"));
  await writeFile(
    path.join(scratch, "CHANGELOG.md"),
    `## [${version}]\n${catalog.releases[version].notes.join("\n")}\n`,
  );
  const render = JSON.parse(await readFile(path.join(assets, "render.json"), "utf8"));
  const quality = JSON.parse(await readFile(path.join(assets, "quality.json"), "utf8"));
  render.approved = false;
  quality.renderSha256 = "stale";
  await writeFile(path.join(assets, "render.json"), json(render));
  await writeFile(path.join(assets, "quality.json"), json(quality));
  const run = () =>
    execFileSync(process.execPath, [path.join(folder, "check.mjs"), "--publish"], {
      env: { PATH: "" },
      stdio: "pipe",
    });
  const saveCatalog = () => writeFile(path.join(folder, "backlog.json"), json(catalog));
  await saveCatalog();
  assert.throws(run, /not been approved for publication/u);

  catalog.publication = "approved";
  await saveCatalog();
  assert.throws(run, /needs visual approval/u);

  render.approved = true;
  const approvedBytes = json(render);
  await writeFile(path.join(assets, "render.json"), approvedBytes);
  assert.throws(run, /needs a passing quality check/u);

  quality.renderSha256 = createHash("sha256").update(approvedBytes).digest("hex");
  quality.decode = false;
  await writeFile(path.join(assets, "quality.json"), json(quality));
  assert.throws(run, /needs a passing quality check/u);

  quality.decode = true;
  await writeFile(path.join(assets, "quality.json"), json(quality));
  assert.match(run().toString(), /Approved 0\.11\.0/u);

  const motion = quality.motion;
  for (const change of [
    { movingFrameRatio: 0 },
    { longestStillSeconds: 3 },
    { largestLumaChange: 30 },
  ]) {
    quality.motion = { ...motion, ...change };
    await writeFile(path.join(assets, "quality.json"), json(quality));
    assert.throws(run, /needs a passing quality check/u);
  }
  quality.motion = motion;
  await writeFile(path.join(assets, "quality.json"), json(quality));

  await writeFile(path.join(assets, "spaces.mp4"), "changed encoded bytes");
  assert.throws(run, /Rendered media changed/u);

  await t.test("a 60 fps slideshow with valid H.264 and AAC is refused", async () => {
    const film = path.join(assets, "spaces.mp4");
    execFileSync(
      "ffmpeg",
      [
        "-v",
        "error",
        "-y",
        "-loop",
        "1",
        "-i",
        path.join(assets, "spaces.png"),
        "-i",
        path.join(root, "public/audio/switch.wav"),
        "-t",
        "1",
        "-r",
        "60",
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-ar",
        "48000",
        "-af",
        "apad",
        film,
      ],
      { stdio: "pipe" },
    );
    render.approved = false;
    render.frames = 60;
    render.posterFrame = 0;
    render.hashes["spaces.mp4"] = createHash("sha256")
      .update(await readFile(film))
      .digest("hex");
    for (const file of Object.keys(render.recipeHashes))
      render.recipeHashes[file] = createHash("sha256")
        .update(await readFile(path.join(folder, file)))
        .digest("hex");
    await writeFile(path.join(assets, "render.json"), json(render));
    assert.throws(
      () => execFileSync(process.execPath, [path.join(folder, "check.mjs")], { stdio: "pipe" }),
      /Motion quality failed/u,
    );
  });
});
