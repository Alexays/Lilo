import assert from "node:assert/strict";
import test from "node:test";
import type { BridgeInitialStatePayload } from "../lib/bridge/protocol";
import { freshStores, stubBridgeWindow } from "./testHarness";

function initialState(
	overrides: Partial<BridgeInitialStatePayload> = {},
): BridgeInitialStatePayload {
	return {
		tabs: [],
		treeItems: [],
		activeTabId: "",
		sidebarWidth: 260,
		sidebarVisible: true,
		...overrides,
	};
}

function stubDocumentElement(): { dataset: Record<string, string> } {
	const root = { dataset: {} as Record<string, string> };
	const doc = (globalThis as { document?: { documentElement?: unknown } }).document;
	if (doc) doc.documentElement = root;
	return root;
}

test("the narrow flag flips at the threshold the bridge carries", async () => {
	const posted = stubBridgeWindow({ document: true });
	const root = stubDocumentElement();
	const loadStore = await freshStores();
	const ui = await loadStore("/src/stores/ui.svelte.ts");

	ui.applyUIInitialState(
		initialState({ sidebarWidth: 260, narrowSidebarWidth: 203 }),
	);
	assert.equal(ui.narrowSidebarWidth(), 203);
	assert.equal(ui.isSidebarNarrow(), false);

	ui.setSidebarWidth(202);
	assert.equal(ui.isSidebarNarrow(), true);
	assert.equal(root.dataset.sidebarNarrow, "");
	assert.equal(posted.at(-1)?.action, "sidebarResized");
	assert.equal(posted.at(-1)?.payload.width, 202);

	ui.setSidebarWidth(203);
	assert.equal(ui.isSidebarNarrow(), false);
	assert.equal("sidebarNarrow" in root.dataset, false);
});

test("the initial state applies a width kept below the threshold", async () => {
	stubBridgeWindow({ document: true });
	const root = stubDocumentElement();
	const loadStore = await freshStores();
	const ui = await loadStore("/src/stores/ui.svelte.ts");

	ui.applyUIInitialState(initialState({ sidebarWidth: 150 }));
	assert.equal(ui.isSidebarNarrow(), true, "the header drops its lights' spacer at once");
	assert.equal(root.dataset.sidebarNarrow, "");

	ui.applyUIInitialState(initialState({ sidebarWidth: 0 }));
	assert.equal(ui.isSidebarNarrow(), false, "a width of none reads as not narrow");
});

test("a different threshold from the bridge steers the flag", async () => {
	stubBridgeWindow({ document: true });
	stubDocumentElement();
	const loadStore = await freshStores();
	const ui = await loadStore("/src/stores/ui.svelte.ts");

	ui.applyUIInitialState(
		initialState({ sidebarWidth: 260, narrowSidebarWidth: 250 }),
	);
	assert.equal(ui.narrowSidebarWidth(), 250);
	assert.equal(ui.isSidebarNarrow(), false);

	ui.setSidebarWidth(240);
	assert.equal(ui.isSidebarNarrow(), true, "under the carried threshold, not a hardcoded one");
});
