import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import {
  boundedRepair,
  runCaptureCommand,
  CaptureEnvironmentError,
} from "../captures/authored-orchestration.ts";

test("authoring repairs keep prior failures and stop after the third failure", async () => {
  const failures: string[] = [];

  const result = await boundedRepair(
    "unread-counts",
    async (attempt, feedback) => {
      await Promise.resolve();
      failures.push(feedback);

      if (attempt < 3) {
        throw new Error(`badge missing in attempt ${attempt}`);
      }

      return { id: "unread-counts", passed: true };
    }
  );

  assert.deepEqual(result, { id: "unread-counts", passed: true });
  assert.match(failures[1], /attempt 1/u);
  assert.match(failures[2], /attempt 1[\s\S]*attempt 2/u);
  await assert.rejects(
    boundedRepair("unread-counts", async (attempt) => {
      await Promise.resolve();
      throw new Error(`bad ${attempt}`);
    }),
    /exhausted[\s\S]*bad 3/u
  );
});

test("unavailable native recording environments do not trigger scenario rewrites", async () => {
  await assert.rejects(
    boundedRepair("unread-counts", async (attempt) => {
      await Promise.resolve();
      assert.equal(attempt, 1);
      throw new CaptureEnvironmentError(
        "Unlock macOS before recording native release media"
      );
    }),
    /Unlock macOS/u
  );
});

test("capture timeouts kill descendants that keep output pipes open", async () => {
  const root = mkdtempSync(path.join(tmpdir(), "lilo-command-timeout-"));
  const pidFile = path.join(root, "child.pid");
  let command: Promise<void> | undefined;

  try {
    const childCode = `require('node:fs').writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);`;
    const parentCode = `require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(childCode)}], {stdio:'inherit'}); setInterval(() => {}, 1000);`;
    const deadline = Promise.withResolvers<never>();

    const timeout = setTimeout(
      () => deadline.reject(new Error("descendant kept the timeout open")),
      2000
    );

    command = runCaptureCommand(
      root,
      process.execPath,
      ["-e", parentCode],
      path.join(root, "process.log"),
      "",
      250
    );

    try {
      await assert.rejects(
        Promise.race([command, deadline.promise]),
        /Timed out/u
      );
    } finally {
      clearTimeout(timeout);
    }
  } finally {
    if (existsSync(pidFile)) {
      try {
        process.kill(Number(readFileSync(pidFile, "utf-8")), "SIGKILL");
      } catch {
        /* The fixed process group is already gone. */
      }
    }

    await command?.catch(() => {});
    rmSync(root, { force: true, recursive: true });
  }
});
