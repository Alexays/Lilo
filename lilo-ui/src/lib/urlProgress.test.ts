import test from "node:test";
import assert from "node:assert/strict";
import {
	computeDisplayedLoadingProgress,
	nextTrickleProgress,
} from "./urlProgress";

test("loading progress starts at a visible floor", () => {
	assert.equal(computeDisplayedLoadingProgress(0, 0), 0.06);
	assert.equal(computeDisplayedLoadingProgress(0.01, 0), 0.06);
});

test("reported progress never jumps to full completion while loading", () => {
	assert.equal(computeDisplayedLoadingProgress(1, 0.5), 0.985);
	assert.equal(computeDisplayedLoadingProgress(0.99, 0.5), 0.985);
});

test("trickle moves quickly early and slows near completion", () => {
	assert.equal(nextTrickleProgress(0.06, 0.06), 0.175);
	assert.equal(nextTrickleProgress(0.4, 0.4), 0.46);
	assert.equal(nextTrickleProgress(0.86, 0.86), 0.88);
	assert.equal(nextTrickleProgress(0.9, 0.9), 0.9);
});

test("trickle never moves high progress backward", () => {
	assert.equal(nextTrickleProgress(0.985, 1), 0.985);
	assert.ok(nextTrickleProgress(0.9, 0.99) >= 0.9);
});

