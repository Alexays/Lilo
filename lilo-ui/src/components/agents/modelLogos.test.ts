import assert from "node:assert/strict";
import test from "node:test";

import { modelLogo, supersededModels } from "./modelLogos";

test("a model a newer version of the same name supersedes is older; names without a version never are", () => {
  const names = ["Default (recommended)", "Opus 5.5", "Fable 5.1", "Haiku 4.5", "Haiku 5.5", "Opus 5", "Fable 5", "Opus 4.10", "Opus 4.8", "Mythos 5.1", "gpt-5"];
  assert.deepEqual([...supersededModels(names)].sort(), ["Fable 5", "Haiku 4.5", "Opus 4.10", "Opus 4.8", "Opus 5"]);
});

test("every Claude family takes the Claude logo", () => {
  assert.ok(modelLogo("Fable 5.1") && modelLogo("Mythos 5.1") === modelLogo("Opus 5.5"));
});
