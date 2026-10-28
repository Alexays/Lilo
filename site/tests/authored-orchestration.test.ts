import assert from "node:assert/strict";
import test from "node:test";

import {
  boundedRepair,
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
