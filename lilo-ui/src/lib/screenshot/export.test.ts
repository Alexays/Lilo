import { test } from "node:test";
import assert from "node:assert/strict";
import { clampCrop } from "./export";

const IMG = { w: 100, h: 80 };

test("clampCrop returns full image when crop is null", () => {
	assert.deepEqual(clampCrop(null, IMG), { x: 0, y: 0, w: 100, h: 80 });
});

test("clampCrop normalizes a negative-size crop", () => {
	assert.deepEqual(clampCrop({ x: 50, y: 40, w: -20, h: -10 }, IMG), { x: 30, y: 30, w: 20, h: 10 });
});

test("clampCrop clips a crop that exceeds image bounds", () => {
	assert.deepEqual(clampCrop({ x: 90, y: 70, w: 50, h: 50 }, IMG), { x: 90, y: 70, w: 10, h: 10 });
});

test("clampCrop clamps a negative origin to zero", () => {
	assert.deepEqual(clampCrop({ x: -10, y: -5, w: 40, h: 30 }, IMG), { x: 0, y: 0, w: 30, h: 25 });
});
