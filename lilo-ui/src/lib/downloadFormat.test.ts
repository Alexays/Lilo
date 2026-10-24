import assert from "node:assert/strict";
import test from "node:test";

import { formatEta, progress } from "./downloadFormat";

test("formatEta and progress are unchanged", () => {
  assert.equal(formatEta(30), "30s");
  assert.equal(formatEta(120), "2m");
  assert.equal(progress({ totalBytes: 200, bytesReceived: 50 }), 25);
  assert.equal(progress({ totalBytes: 0, bytesReceived: 50 }), 0);
});
