import { test } from "node:test";
import assert from "node:assert/strict";
import { createHistory } from "./history";

test("push then undo restores previous snapshot", () => {
	const h = createHistory<number[]>([]);
	h.push([1]);
	h.push([1, 2]);
	assert.deepEqual(h.current(), [1, 2]);
	assert.deepEqual(h.undo(), [1]);
	assert.deepEqual(h.current(), [1]);
});

test("redo reapplies an undone snapshot", () => {
	const h = createHistory<number[]>([]);
	h.push([1]);
	h.undo();
	assert.deepEqual(h.redo(), [1]);
});

test("push after undo truncates the redo branch", () => {
	const h = createHistory<number[]>([]);
	h.push([1]);
	h.push([1, 2]);
	h.undo(); // back to [1]
	h.push([1, 9]);
	assert.equal(h.canRedo(), false);
	assert.deepEqual(h.current(), [1, 9]);
});

test("undo at the base is a no-op", () => {
	const h = createHistory<number[]>([]);
	assert.equal(h.canUndo(), false);
	assert.deepEqual(h.undo(), []);
});
