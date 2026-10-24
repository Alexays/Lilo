import { test } from "node:test";
import assert from "node:assert/strict";
import { computeIndicatorRect } from "./selectionIndicator";

test("hidden when there is no active row", () => {
  assert.deepEqual(computeIndicatorRect(null, { top: 100, left: 0 }, 0), {
    top: 0,
    left: 0,
    width: 0,
    height: 0,
    visible: false,
  });
});

test("positions relative to the container content origin on both axes", () => {
  // row at viewport (left=50, top=140), container origin at (left=40, top=100)
  const rect = computeIndicatorRect(
    { top: 140, left: 50, width: 200, height: 30 },
    { top: 100, left: 40 },
    0,
  );
  assert.deepEqual(rect, {
    top: 40,
    left: 10,
    width: 200,
    height: 30,
    visible: true,
  });
});

test("adds the scroll offset so the indicator sits in content coordinates", () => {
  const rect = computeIndicatorRect(
    { top: 140, left: 50, width: 200, height: 30 },
    { top: 100, left: 40 },
    250,
  );
  assert.deepEqual(rect, {
    top: 290,
    left: 10,
    width: 200,
    height: 30,
    visible: true,
  });
});
