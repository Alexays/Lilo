import assert from "node:assert/strict";
import test from "node:test";
import { flushSync } from "svelte";
import type { BridgeInitialStatePayload } from "../lib/bridge/protocol";
import { tab } from "./testFixtures";
import { freshStores, stubBridgeWindow } from "./testHarness";

const spaceId = "space";

async function withStore() {
	const sent = stubBridgeWindow({ document: true });
	const loadStore = await freshStores();

	const tabsModule = await loadStore("/src/stores/tabs.svelte.ts");
	const sidebarModule = await loadStore("/src/stores/sidebar.svelte.ts");
	const spacesModule = await loadStore("/src/stores/spaces.svelte.ts");
	const commandBarModule = await loadStore("/src/stores/commandBar.svelte.ts");

	tabsModule.initTabStore();
	commandBarModule.initCommandBarStore();

	const receive = (
		globalThis as { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } }
	).window.__lilo!.receive;

	const seed = (tabs: BridgeInitialStatePayload["tabs"]) => {
		const initial = {
			activeSpaceId: spaceId,
			activeTabId: "blank-tab",
			sidebarWidth: 0,
			sidebarVisible: true,
			spaces: [
				{
					id: spaceId,
					name: "Space",
					icon: "S",
					color: "#5865f2",
					profileId: "profile",
					isPrivate: false,
					sortOrder: 0,
				},
			],
			tabs,
			treeItems: [],
		} as unknown as BridgeInitialStatePayload;
		spacesModule.applySpaceInitialState(initial);
		sidebarModule.applySidebarTabInitialState(initial);
		flushSync();
	};

	const closes = () => sent.filter((m) => m.action === "closeTab").map((m) => m.payload.id);

	const openCommandBar = commandBarModule.openCommandBar as (
		prefill?: string,
		mode?: string,
		closeBlankTabOnDismiss?: boolean,
	) => void;
	const closeCommandBar = commandBarModule.closeCommandBar as () => void;

	return { sent, closes, receive, seed, openCommandBar, closeCommandBar, commandBarModule };
}

test("dismissing with only a blank tab keeps it (closing it would close the window)", async () => {
	const ctx = await withStore();
	ctx.seed([tab("blank-tab", spaceId, { url: "" })]);

	ctx.openCommandBar("", true);
	ctx.closeCommandBar();
	flushSync();

	assert.deepEqual(ctx.closes(), [], "must not close the last tab on dismiss");
});

test("the deferred blank tab is closed once another tab becomes active", async () => {
	const ctx = await withStore();
	ctx.seed([tab("blank-tab", spaceId, { url: "" })]);

	ctx.openCommandBar("", true);
	ctx.closeCommandBar();
	flushSync();
	assert.deepEqual(ctx.closes(), [], "not closed yet: still the only tab");

	// User clicked a bookmark: it opens and becomes active. Now there are two tabs.
	ctx.receive({
		event: "browserStatePatch",
		changedSpaceId: spaceId,
		operations: [
			{
				kind: "sidebarChanged",
				spaceId,
				activeTabId: "bookmark-tab",
				upsertTabs: [tab("bookmark-tab", spaceId)],
			},
		],
	});
	flushSync();

	assert.deepEqual(ctx.closes(), ["blank-tab"], "blank tab cleaned up after the bookmark opens");
});

test("dismissing with other tabs open closes the blank tab immediately", async () => {
	const ctx = await withStore();
	ctx.seed([tab("blank-tab", spaceId, { url: "" }), tab("other-tab", spaceId)]);

	ctx.openCommandBar("", true);
	ctx.closeCommandBar();
	flushSync();

	assert.deepEqual(ctx.closes(), ["blank-tab"]);
});

test("dismissing a new-tab command bar opened over a terminal keeps the terminal", async () => {
	const ctx = await withStore();
	ctx.seed([tab("blank-tab", spaceId, { url: "", kind: "terminal" }), tab("other-tab", spaceId)]);

	ctx.openCommandBar("", true);
	ctx.closeCommandBar();
	flushSync();

	assert.deepEqual(ctx.closes(), []);
});

test("a typed address reaches native marked as typed, a history result does not", async () => {
	const ctx = await withStore();
	ctx.seed([tab("blank-tab", spaceId, { url: "" }), tab("other-tab", spaceId)]);
	const store = ctx.commandBarModule as {
		setQuery(query: string): void;
		executeSelected(): void;
		executeSelectedInNewTab(): void;
		executeRawQuery(): void;
		executeResult(result: { id: string; kind: string; title: string; payload: object; url: string }): void;
	};
	const navigations = () => ctx.sent.filter((m) => m.action === "navigate" || m.action === "createTab").map((m) => m.payload);

	for (const run of [store.executeSelected, store.executeSelectedInNewTab, store.executeRawQuery]) {
		ctx.openCommandBar("");
		store.setQuery("youtube.com");
		flushSync();
		run();
		flushSync();
	}
	store.executeResult({ id: "h", kind: "history", title: "YouTube", payload: {}, url: "https://youtube.com/" });

	assert.deepEqual(navigations(), [
		{ url: "https://youtube.com", typed: true },
		{ url: "https://youtube.com", typed: true },
		{ url: "https://youtube.com", typed: true },
		{ url: "https://youtube.com/", typed: false },
	]);
});
