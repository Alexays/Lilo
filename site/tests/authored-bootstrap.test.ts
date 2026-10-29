import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

test("capture bootstrap ignores missing and corrupted prior media without changing the archive", () => {
  const root = mkdtempSync(path.join(tmpdir(), "lilo-bootstrap-"));

  try {
    mkdirSync(path.join(root, "scripts"));
    mkdirSync(path.join(root, "lilo-ui"));
    const source = path.join(root, "site/src/assets/releases/0.9.0");
    mkdirSync(source, { recursive: true });
    copyFileSync(
      new URL("../../scripts/copy_release_media.py", import.meta.url),
      path.join(root, "scripts/copy_release_media.py")
    );
    writeFileSync(
      path.join(root, "lilo-ui/package.json"),
      '{"version":"0.9.0"}'
    );

    const metadata = JSON.stringify({
      approval: { passed: true },
      plan: { highlights: [{ id: "new-feature" }] },
      recordings: { "new-feature": { posterDigest: "a".repeat(64) } },
      release: "0.9.0",
      schemaVersion: 3,
    });

    writeFileSync(path.join(source, "capture.json"), metadata);

    for (const corrupt of [false, true]) {
      if (corrupt) {
        writeFileSync(
          path.join(source, "new-feature-native.png"),
          "corrupt pixels"
        );
      }

      const normal = spawnSync("python3", [
        "-B",
        path.join(root, "scripts/copy_release_media.py"),
      ]);

      assert.notEqual(normal.status, 0);

      const bootstrap = spawnSync(
        "python3",
        ["-B", path.join(root, "scripts/copy_release_media.py")],
        { env: { ...process.env, LILO_CAPTURE_BUILD: "1" } }
      );

      assert.equal(bootstrap.status, 0, bootstrap.stderr.toString());
      assert.equal(
        readFileSync(path.join(source, "capture.json"), "utf-8"),
        metadata
      );
    }
  } finally {
    rmSync(root, { force: true, recursive: true });
  }
});
