import assert from "node:assert/strict";
import test from "node:test";
import { insertShadowItem, removeShadowItems } from "./projection";
import type { DndItem } from "./types";

const tab = (id: string): DndItem => ({
	id,
	kind: "tab",
});

test("removeShadowItems and insertShadowItem maintain in-flow placeholders", () => {
	const items = [tab("a"), tab("b")];
	const withShadow = insertShadowItem(items, tab("c"), 1);

	assert.deepEqual(withShadow.map((item) => item.id), ["a", "dnd-shadow:c", "b"]);
	assert.deepEqual(removeShadowItems(withShadow).map((item) => item.id), ["a", "b"]);
});
