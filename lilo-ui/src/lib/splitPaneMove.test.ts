import assert from "node:assert/strict";
import test from "node:test";

import { paneMoveTarget } from "./splitPaneMove";
import type { BridgeSplitPaneFrame } from "./bridge/protocol";

const left: BridgeSplitPaneFrame = { tabId: "tab-left", x: 0, y: 0, width: 0.5, height: 1 };
const right: BridgeSplitPaneFrame = { tabId: "tab-right", x: 0.5, y: 0, width: 0.5, height: 1 };

test("a drop in a pane's middle swaps with it", () => {
	assert.deepEqual(paneMoveTarget([left, right], 0.75, 0.5, "tab-left"), {
		tabId: "tab-right",
		side: "replace",
	});
});

test("a drop near an edge takes that half", () => {
	assert.deepEqual(paneMoveTarget([left, right], 0.55, 0.5, "tab-left"), {
		tabId: "tab-right",
		side: "left",
	});
	assert.deepEqual(paneMoveTarget([left, right], 0.95, 0.5, "tab-left"), {
		tabId: "tab-right",
		side: "right",
	});
	assert.deepEqual(paneMoveTarget([left, right], 0.75, 0.05, "tab-left"), {
		tabId: "tab-right",
		side: "top",
	});
	assert.deepEqual(paneMoveTarget([left, right], 0.75, 0.95, "tab-left"), {
		tabId: "tab-right",
		side: "bottom",
	});
});

test("the dragged pane's own frame is not a target", () => {
	assert.equal(paneMoveTarget([left, right], 0.25, 0.5, "tab-left"), null);
});

test("outside every pane there is no target", () => {
	assert.equal(paneMoveTarget([left, right], 1.1, 0.5, "tab-left"), null);
	assert.equal(paneMoveTarget([], 0.5, 0.5, "tab-left"), null);
});

test("a stacked pane offers top and bottom edges", () => {
	const top: BridgeSplitPaneFrame = { tabId: "tab-top", x: 0, y: 0, width: 1, height: 0.5 };
	const bottom: BridgeSplitPaneFrame = { tabId: "tab-bottom", x: 0, y: 0.5, width: 1, height: 0.5 };
	assert.deepEqual(paneMoveTarget([top, bottom], 0.5, 0.55, "tab-top"), {
		tabId: "tab-bottom",
		side: "top",
	});
	assert.deepEqual(paneMoveTarget([top, bottom], 0.5, 0.7, "tab-top"), {
		tabId: "tab-bottom",
		side: "replace",
	});
});

test("a full split only trades places", () => {
	const third: BridgeSplitPaneFrame = { tabId: "tab-third", x: 0.5, y: 0.5, width: 0.5, height: 0.5 };
	assert.deepEqual(paneMoveTarget([left, third, right], 0.75, 0.75, "tab-left"), {
		tabId: "tab-third",
		side: "replace",
	});
});
