import assert from "node:assert/strict";
import { test } from "node:test";

import { demoFeatures } from "../../src/lib/i18n.ts";

test("the feature explorer has matching English and French entries without duplicate destinations", () => {
  const english = demoFeatures.en.map((feature) => feature.id);
  const french = demoFeatures.fr.map((feature) => feature.id);
  assert.deepEqual(french, english);
  assert.equal(new Set(english).size, english.length);
  assert.deepEqual(
    demoFeatures.fr
      .filter((feature) => feature.mac)
      .map((feature) => feature.id),
    demoFeatures.en
      .filter((feature) => feature.mac)
      .map((feature) => feature.id)
  );
});
