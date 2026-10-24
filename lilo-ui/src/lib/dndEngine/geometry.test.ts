import assert from "node:assert/strict";
import test from "node:test";
import {
	applyTargetHysteresis,
	resolveTargetFromPoint,
	type DndZoneSnapshot,
} from "./geometry";

function rect(
	left: number,
	top: number,
	width: number,
	height: number,
) {
	return {
		left,
		top,
		right: left + width,
		bottom: top + height,
		width,
		height,
	};
}

const horizontalZone: DndZoneSnapshot = {
	id: "spaces",
	axis: "horizontal",
	rect: rect(0, 0, 200, 48),
	items: [
		{ id: "a", rect: rect(20, 6, 40, 36) },
		{ id: "b", rect: rect(70, 6, 40, 36) },
		{ id: "c", rect: rect(120, 6, 40, 36) },
	],
};

test("resolveTargetFromPoint resolves horizontal insertion before the first item", () => {
	assert.deepEqual(
		resolveTargetFromPoint({ x: 10, y: 24 }, horizontalZone),
		{
			zoneId: "spaces",
			index: 0,
			axis: "horizontal",
		},
	);
});

test("resolveTargetFromPoint resolves horizontal insertion between item midpoints", () => {
	assert.deepEqual(
		resolveTargetFromPoint({ x: 66, y: 24 }, horizontalZone),
		{
			zoneId: "spaces",
			index: 1,
			axis: "horizontal",
		},
	);
});

test("resolveTargetFromPoint resolves horizontal insertion after the last item", () => {
	assert.deepEqual(
		resolveTargetFromPoint({ x: 190, y: 24 }, horizontalZone),
		{
			zoneId: "spaces",
			index: 3,
			axis: "horizontal",
		},
	);
});

test("resolveTargetFromPoint returns null outside the zone rect", () => {
	assert.equal(resolveTargetFromPoint({ x: 10, y: 80 }, horizontalZone), null);
});

test("resolveTargetFromPoint resolves empty zones to index zero", () => {
	assert.deepEqual(
		resolveTargetFromPoint({
			x: 12,
			y: 12,
		}, {
			id: "empty",
			axis: "vertical",
			rect: rect(0, 0, 120, 40),
			items: [],
		}),
		{
			zoneId: "empty",
			index: 0,
			axis: "vertical",
		},
	);
});

test("resolveTargetFromPoint resolves vertical insertion from row midpoints", () => {
	const zone: DndZoneSnapshot = {
		id: "tabs",
		axis: "vertical",
		rect: rect(0, 0, 240, 140),
		items: [
			{ id: "a", rect: rect(0, 0, 240, 30) },
			{ id: "b", rect: rect(0, 34, 240, 30) },
			{ id: "c", rect: rect(0, 68, 240, 30) },
		],
	};

	assert.deepEqual(resolveTargetFromPoint({ x: 20, y: 52 }, zone), {
		zoneId: "tabs",
		index: 2,
		axis: "vertical",
	});
});

test("resolveTargetFromPoint resolves grid insertion by row order", () => {
	const zone: DndZoneSnapshot = {
		id: "bookmarks",
		axis: "grid",
		rect: rect(0, 0, 120, 120),
		items: [
			{ id: "a", rect: rect(0, 0, 48, 48) },
			{ id: "b", rect: rect(56, 0, 48, 48) },
			{ id: "c", rect: rect(0, 56, 48, 48) },
		],
	};

	assert.deepEqual(resolveTargetFromPoint({ x: 112, y: 100 }, zone), {
		zoneId: "bookmarks",
		index: 3,
		axis: "grid",
	});
});

test("resolveTargetFromPoint resolves grid insertion before the first tile", () => {
	const zone: DndZoneSnapshot = {
		id: "bookmarks",
		axis: "grid",
		rect: rect(0, 0, 120, 120),
		items: [
			{ id: "a", rect: rect(0, 0, 48, 48) },
			{ id: "b", rect: rect(56, 0, 48, 48) },
			{ id: "c", rect: rect(0, 56, 48, 48) },
		],
	};

	assert.deepEqual(resolveTargetFromPoint({ x: 6, y: 24 }, zone), {
		zoneId: "bookmarks",
		index: 0,
		axis: "grid",
	});
});

test("resolveTargetFromPoint resolves grid item placement from horizontal midpoint", () => {
	const zone: DndZoneSnapshot = {
		id: "bookmarks",
		axis: "grid",
		rect: rect(0, 0, 120, 120),
		items: [
			{ id: "a", rect: rect(0, 0, 48, 48) },
			{ id: "b", rect: rect(56, 0, 48, 48) },
		],
	};

	assert.deepEqual(resolveTargetFromPoint({ x: 96, y: 6 }, zone), {
		zoneId: "bookmarks",
		index: 2,
		axis: "grid",
	});
});

test("applyTargetHysteresis keeps the previous linear index near an edge", () => {
	const previous = {
		zoneId: "spaces",
		index: 1,
		axis: "horizontal" as const,
	};
	const next = {
		zoneId: "spaces",
		index: 2,
		axis: "horizontal" as const,
	};

	assert.deepEqual(
		applyTargetHysteresis({ x: 92, y: 24 }, horizontalZone, next, previous, 6),
		previous,
	);
	assert.deepEqual(
		applyTargetHysteresis({ x: 98, y: 24 }, horizontalZone, next, previous, 6),
		next,
	);
});

test("resolveTargetFromPoint appends when the pointer is below the last occupied grid row", () => {
	// The dragged tile's placeholder alone on a second row is not part of the snapshot: the
	// zone still spans that row, and aiming there must keep meaning "last", not snap to row one.
	assert.deepEqual(
		resolveTargetFromPoint({ x: 70, y: 58 }, {
			id: "bookmarks",
			axis: "grid",
			rect: rect(0, 0, 200, 76),
			items: [
				{ id: "a", rect: rect(0, 0, 40, 34) },
				{ id: "b", rect: rect(42, 0, 40, 34) },
				{ id: "c", rect: rect(84, 0, 40, 34) },
			],
		}),
		{ zoneId: "bookmarks", index: 3, axis: "grid" },
	);
});
