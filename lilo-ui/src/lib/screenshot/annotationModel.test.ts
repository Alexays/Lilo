import { test } from "node:test";
import assert from "node:assert/strict";
import {
	createAnnotation,
	normalizeBox,
	hitTest,
	moveAnnotation,
	resizeAnnotation,
	boundsOfPoints,
	smoothPath,
} from "./annotationModel";

test("createAnnotation sets type, box, and a non-empty id", () => {
	const a = createAnnotation("rect", { x: 1, y: 2, w: 3, h: 4 }, "#ff0000", 3);
	assert.equal(a.type, "rect");
	assert.deepEqual(a.box, { x: 1, y: 2, w: 3, h: 4 });
	assert.equal(a.color, "#ff0000");
	assert.equal(a.strokeWidth, 3);
	assert.ok(a.id.length > 0);
});

test("normalizeBox flips negative width/height to a positive origin box", () => {
	assert.deepEqual(normalizeBox({ x: 10, y: 10, w: -4, h: -6 }), { x: 6, y: 4, w: 4, h: 6 });
});

test("hitTest returns the topmost (last) annotation containing the point", () => {
	const bottom = createAnnotation("rect", { x: 0, y: 0, w: 100, h: 100 }, "#000", 2);
	const top = createAnnotation("rect", { x: 10, y: 10, w: 20, h: 20 }, "#000", 2);
	const hit = hitTest([bottom, top], { x: 15, y: 15 });
	assert.equal(hit?.id, top.id);
});

test("hitTest returns null when no annotation contains the point", () => {
	const a = createAnnotation("rect", { x: 0, y: 0, w: 10, h: 10 }, "#000", 2);
	assert.equal(hitTest([a], { x: 50, y: 50 }), null);
});

test("moveAnnotation shifts the box by a delta without mutating the input", () => {
	const a = createAnnotation("rect", { x: 5, y: 5, w: 10, h: 10 }, "#000", 2);
	const moved = moveAnnotation(a, 3, -2);
	assert.deepEqual(moved.box, { x: 8, y: 3, w: 10, h: 10 });
	assert.deepEqual(a.box, { x: 5, y: 5, w: 10, h: 10 });
});

test("resizeAnnotation se: grows width/height from the south-east handle", () => {
	const a = createAnnotation("rect", { x: 0, y: 0, w: 10, h: 10 }, "#000", 2);
	const r = resizeAnnotation(a, "se", 5, 3);
	assert.deepEqual(r.box, { x: 0, y: 0, w: 15, h: 13 });
});

test("resizeAnnotation nw: moves origin and shrinks", () => {
	const a = createAnnotation("rect", { x: 10, y: 10, w: 10, h: 10 }, "#000", 2);
	const r = resizeAnnotation(a, "nw", 4, 2);
	assert.deepEqual(r.box, { x: 14, y: 12, w: 6, h: 8 });
});

test("resizeAnnotation n: only top edge moves", () => {
	const a = createAnnotation("rect", { x: 0, y: 10, w: 10, h: 10 }, "#000", 2);
	const r = resizeAnnotation(a, "n", 0, 4);
	assert.deepEqual(r.box, { x: 0, y: 14, w: 10, h: 6 });
});

test("resizeAnnotation does not mutate the input", () => {
	const a = createAnnotation("rect", { x: 0, y: 0, w: 10, h: 10 }, "#000", 2);
	resizeAnnotation(a, "se", 5, 5);
	assert.deepEqual(a.box, { x: 0, y: 0, w: 10, h: 10 });
});

test("boundsOfPoints returns the axis-aligned bounding box of the points", () => {
	const b = boundsOfPoints([{ x: 5, y: 8 }, { x: 15, y: 3 }, { x: 10, y: 20 }]);
	assert.deepEqual(b, { x: 5, y: 3, w: 10, h: 17 });
});

test("boundsOfPoints returns a zero box for no points", () => {
	assert.deepEqual(boundsOfPoints([]), { x: 0, y: 0, w: 0, h: 0 });
});

test("moveAnnotation translates freehand points along with the box", () => {
	const a = { ...createAnnotation("draw", { x: 0, y: 0, w: 10, h: 10 }, "#000", 3), points: [{ x: 0, y: 0 }, { x: 10, y: 10 }] };
	const moved = moveAnnotation(a, 5, -3);
	assert.deepEqual(moved.box, { x: 5, y: -3, w: 10, h: 10 });
	assert.deepEqual(moved.points, [{ x: 5, y: -3 }, { x: 15, y: 7 }]);
	// input not mutated
	assert.deepEqual(a.points, [{ x: 0, y: 0 }, { x: 10, y: 10 }]);
});

test("smoothPath returns empty string for no points", () => {
	assert.equal(smoothPath([]), "");
});

test("smoothPath draws a dot for a single point", () => {
	assert.match(smoothPath([{ x: 4, y: 6 }]), /^M4 6/);
});

test("smoothPath starts at the first point and is non-empty for a stroke", () => {
	const d = smoothPath([{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }]);
	assert.match(d, /^M0 0/);
	assert.ok(d.length > 6);
});
