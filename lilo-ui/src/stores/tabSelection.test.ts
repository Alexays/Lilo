import assert from "node:assert/strict";
import test from "node:test";
import { flushSync } from "svelte";
import type { BridgeInitialStatePayload } from "../lib/bridge/protocol";
import { freshStores, stubBridgeWindow } from "./testHarness";

const SPACES = [
	{ id: "home", name: "Home", icon: "🏠", color: "#5865f2", profileId: "personal", isPrivate: false, sortOrder: 0 },
	{ id: "work", name: "Work", icon: "💼", color: "#5865f2", profileId: "personal", isPrivate: false, sortOrder: 1 },
];

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- StoreModule spreads lose their keys to svelte-check
async function withSelection(activeSpaceId = "home"): Promise<any> {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const spaces = await loadStore("/src/stores/spaces.svelte.ts");
	const selection = await loadStore("/src/stores/tabSelection.svelte.ts");
	const apply = (spaceId: string) => {
		spaces.applySpaceInitialState({ activeSpaceId: spaceId, spaces: SPACES } as unknown as BridgeInitialStatePayload);
		flushSync();
	};
	apply(activeSpaceId);
	return { ...selection, apply };
}

test("cmd-click toggles tabs in and out of the selection", async () => {
	const { isTabSelected, getSelectedTabIds, toggleTabSelection } = await withSelection();
	toggleTabSelection("a");
	toggleTabSelection("c");
	assert.deepEqual([...getSelectedTabIds()].sort(), ["a", "c"]);
	assert.ok(isTabSelected("a"));
	toggleTabSelection("a");
	assert.deepEqual([...getSelectedTabIds()], ["c"]);
	assert.ok(!isTabSelected("a"));
});

test("shift-click selects the range back to the anchor in sidebar order", async () => {
	const { getSelectedTabIds, toggleTabSelection, extendTabSelection } = await withSelection();
	toggleTabSelection("b");
	extendTabSelection(["a", "b", "c", "d", "e"], "d");
	assert.deepEqual([...getSelectedTabIds()].sort(), ["b", "c", "d"]);
	// The anchor holds for the next range, backwards included.
	extendTabSelection(["a", "b", "c", "d", "e"], "a");
	assert.deepEqual([...getSelectedTabIds()].sort(), ["a", "b"]);
});

test("a shift-click whose anchor left the list selects the clicked tab alone", async () => {
	const { getSelectedTabIds, toggleTabSelection, extendTabSelection } = await withSelection();
	toggleTabSelection("z");
	extendTabSelection(["a", "b", "c"], "b");
	assert.deepEqual([...getSelectedTabIds()], ["b"]);
});

test("a plain click collapses the selection and moves the anchor", async () => {
	const { getSelectedTabIds, toggleTabSelection, selectTabOnly, extendTabSelection } = await withSelection();
	toggleTabSelection("a");
	toggleTabSelection("c");
	selectTabOnly("d");
	assert.equal(getSelectedTabIds().size, 0);
	extendTabSelection(["a", "b", "c", "d"], "b");
	assert.deepEqual([...getSelectedTabIds()].sort(), ["b", "c", "d"]);
});

test("the selection does not leak into another Space", async () => {
	const { isTabSelected, getSelectedTabIds, toggleTabSelection, apply } = await withSelection("home");
	toggleTabSelection("a");
	assert.ok(isTabSelected("a"));
	apply("work");
	assert.ok(!isTabSelected("a"));
	assert.equal(getSelectedTabIds().size, 0);
});
