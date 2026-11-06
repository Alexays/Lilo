import assert from "node:assert/strict";
import { test } from "node:test";
import { stagedFiles } from "./stage-native.mjs";

const registry = {
  "1.2.0": {
    highlights: [
      { id: "tabs", media: "loop" },
      { id: "settings", media: "image" },
      { id: "calm", illustration: "calm" },
    ],
  },
};

test("stages each highlight's media and nothing for the rest", () => {
  assert.deepEqual(stagedFiles("1.2.0", registry), ["tabs.png", "tabs.mp4", "settings.png"]);
});

test("a release without highlights stages nothing", () => {
  assert.deepEqual(stagedFiles("1.2.1", registry), []);
});
