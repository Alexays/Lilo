import assert from "node:assert/strict";
import { test } from "node:test";

import { createDemoHost } from "../../src/demo/host.ts";

test("the native release readiness probe stays quiet in the website demo", () => {
  const host = createDemoHost("en");
  host.dispatch("requestWhatsNew", {});
  assert.equal(host.snapshot().notice, "");
});
