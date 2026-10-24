import assert from "node:assert/strict";
import test from "node:test";
import {
	dndItemsForSpaces,
	flipDurationForSpaceDndItem,
	projectSpaceItemsWithShadow,
	spaceDndKey,
	spaceMoveIndexFromProjectedItems,
} from "./adapters/spaces";
import { isShadowItem } from "./projection";

test("dndItemsForSpaces creates space items and preserves private spaces visually", () => {
	assert.deepEqual(dndItemsForSpaces([
		{ id: "a", isPrivate: false },
		{ id: "private", isPrivate: true },
	]), [
		{ id: "a", kind: "space", isPrivate: false },
		{ id: "private", kind: "space", isPrivate: true },
	]);
});

test("projectSpaceItemsWithShadow inserts one in-flow placeholder", () => {
	const items = dndItemsForSpaces([
		{ id: "a", isPrivate: false },
		{ id: "b", isPrivate: false },
		{ id: "c", isPrivate: false },
	]);

	const projected = projectSpaceItemsWithShadow(items, "b", 0);

	assert.deepEqual(projected.map((item) => item.id), ["dnd-shadow:b", "a", "c"]);
	assert.equal(isShadowItem(projected[0]), true);
	assert.equal(flipDurationForSpaceDndItem(projected[0]), 0);
	assert.equal(spaceDndKey(projected[0]), "dnd-shadow:b:shadow");
});

test("spaceMoveIndexFromProjectedItems resolves persistent index after shadow projection", () => {
	const previousItems = dndItemsForSpaces([
		{ id: "a", isPrivate: false },
		{ id: "b", isPrivate: false },
		{ id: "private", isPrivate: true },
		{ id: "c", isPrivate: false },
	]);
	const nextItems = projectSpaceItemsWithShadow(previousItems, "b", 3);

	assert.equal(spaceMoveIndexFromProjectedItems({
		draggedId: "b",
		previousItems,
		nextItems,
	}), 2);
});

test("spaceMoveIndexFromProjectedItems rejects private and no-op drags", () => {
	const previousItems = dndItemsForSpaces([
		{ id: "a", isPrivate: false },
		{ id: "private", isPrivate: true },
	]);

	assert.equal(spaceMoveIndexFromProjectedItems({
		draggedId: "private",
		previousItems,
		nextItems: projectSpaceItemsWithShadow(previousItems, "private", 0),
	}), null);
	assert.equal(spaceMoveIndexFromProjectedItems({
		draggedId: "a",
		previousItems,
		nextItems: projectSpaceItemsWithShadow(previousItems, "a", 0),
	}), null);
});
