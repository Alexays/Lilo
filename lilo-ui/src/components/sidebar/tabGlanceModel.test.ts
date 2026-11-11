import assert from "node:assert/strict";
import test from "node:test";

import { clampGlanceSize, formatGlanceSize, GLANCE_DEFAULT_SIZE, parseGlanceSize } from "./tabGlanceModel";

const roomy = { width: 2000, height: 2000 };

test("reads back the size it stores", () => {
	assert.deepEqual(parseGlanceSize(formatGlanceSize({ width: 480, height: 600 })), { width: 480, height: 600 });
});

test("falls back to the compact size without a valid setting", () => {
	assert.deepEqual(parseGlanceSize(""), GLANCE_DEFAULT_SIZE);
	assert.deepEqual(parseGlanceSize("wide"), GLANCE_DEFAULT_SIZE);
});

test("keeps the card between its bounds", () => {
	assert.deepEqual(clampGlanceSize({ width: 10, height: 10 }, roomy), { width: 260, height: 240 });
	assert.deepEqual(clampGlanceSize({ width: 5000, height: 5000 }, roomy), { width: 720, height: 900 });
});

test("shrinks to the room the window leaves, but never under the minimum", () => {
	assert.deepEqual(clampGlanceSize({ width: 600, height: 700 }, { width: 500, height: 450 }), { width: 500, height: 450 });
	assert.deepEqual(clampGlanceSize({ width: 600, height: 700 }, { width: 100, height: 100 }), { width: 260, height: 240 });
});
