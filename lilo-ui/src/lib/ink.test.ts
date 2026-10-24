import assert from "node:assert/strict";
import test from "node:test";
import { arrowPath, dashArray, prefersDarkText, snapAngle } from "./ink";

test("dash styles scale with the line", () => {
	assert.equal(dashArray("solid", 2), undefined);
	assert.equal(dashArray("dashed", 2), "8 6");
	assert.equal(dashArray("dotted", 4), "0 10");
});

test("snapAngle turns a line to 15 degree steps", () => {
	const end = snapAngle({ x: 0, y: 0 }, { x: 100, y: 3 });
	assert.ok(Math.abs(end.y) < 1e-9);
	assert.ok(Math.abs(end.x - Math.hypot(100, 3)) < 1e-9);
});

test("light fills take dark text", () => {
	assert.equal(prefersDarkText("#ffcc00"), true);
	assert.equal(prefersDarkText("#0a84ff"), false);
	assert.equal(prefersDarkText("#1c1c1e"), false);
});

test("an arrow takes a head at each end it asks for", () => {
	const heads = (path: { heads: string }) => path.heads.split("M").length - 1;
	assert.equal(heads(arrowPath({ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 0, y: 0 }, 2, "none")), 0);
	assert.equal(heads(arrowPath({ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 0, y: 0 }, 2, "end")), 1);
	assert.equal(heads(arrowPath({ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 0, y: 0 }, 2, "both")), 2);
});
