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
		closeBlankTabOnDismiss?: boolean,
	) => void;
	const closeCommandBar = commandBarModule.closeCommandBar as () => void;

	return { sent, closes, receive, seed, openCommandBar, closeCommandBar, commandBarModule, loadStore };
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


test("compact new-tab results stay the same after clearing scopes, queries, and dismissing", async () => {
 const ctx = await withStore();
 const settings = await ctx.loadStore("/src/stores/settings.svelte.ts");
 settings.initSettingsStore();
 ctx.receive({ event: "settingsLoaded", settings: { commandBarLayout: "compact" } });
 ctx.seed([tab("blank-tab", spaceId, { url: "" }), tab("other-tab", spaceId, { title: "Example" })]);
 const bar = ctx.commandBarModule;
 bar.applyCommandBarInitialState();
 flushSync();
 assert.equal(bar.isCommandBarDocked(), true);
 const initial = bar.getResults().map((result: { id: string }) => result.id);
 assert.ok(initial.length > 0, "the idle landing still offers useful tabs and actions");
 assert.equal(bar.getSections().some((section: { tiles?: boolean }) => section.tiles), false);
 ctx.openCommandBar();
 flushSync();
 assert.equal(bar.isCommandBarDocked(), false);
 assert.deepEqual(bar.getResults().map((result: { id: string }) => result.id), initial);
 for (const scope of ["bookmark", "tab", "action", "history", "terminal", "archive"]) {
  bar.setCommandBarScope(scope);
  bar.setCommandBarScope("all");
  flushSync();
  assert.deepEqual(bar.getResults().map((result: { id: string }) => result.id), initial, scope);
 }
 bar.setQuery("example query");
 bar.setQuery("");
 flushSync();
 assert.deepEqual(bar.getResults().map((result: { id: string }) => result.id), initial);
 ctx.closeCommandBar();
 flushSync();
 assert.equal(bar.isCommandBarDocked(), true);
 assert.deepEqual(bar.getResults().map((result: { id: string }) => result.id), initial);
});


test("new-tab intent creates destinations on submit, cancels without a tab, and resets for address editing", async () => {
 const ctx = await withStore();
 ctx.seed([tab("blank-tab", spaceId, { url: "https://current.example/" }), tab("other-tab", spaceId)]);
 const bar = ctx.commandBarModule;
 const mutations = () => ctx.sent.filter((message) => ["createTab", "navigate", "closeTab", "switchTab"].includes(message.action));
 const open = () => ctx.receive({ event: "openCommandBar", createOnSubmit: true });
 open();
 assert.equal(bar.isCommandBarOpen(), true);
 assert.deepEqual(mutations(), []);
 ctx.closeCommandBar();
 assert.deepEqual(mutations(), []);
 for (const raw of [false, true]) {
  open();
  bar.setQuery("https://destination.example/new");
  if (raw) bar.executeRawQuery();
  else bar.executeSelected();
  assert.equal(mutations().at(-1)?.action, "createTab");
  assert.equal(mutations().at(-1)?.payload.url, "https://destination.example/new");
 }
 open();
 bar.setQuery("a test search");
 bar.executeRawQuery();
 assert.equal(mutations().at(-1)?.action, "createTab");
 assert.match(String(mutations().at(-1)?.payload.url), /search/);
 const beforeSwitch = mutations().length;
 open();
 bar.executeResult({ id: "other", kind: "tab", title: "Other", payload: { tabId: "other-tab" }, url: "https://other.example/" });
 assert.deepEqual(mutations().slice(beforeSwitch).map((message) => message.action), ["switchTab"]);
 ctx.openCommandBar();
 bar.setQuery("https://edit.example/");
 bar.executeRawQuery();
 assert.equal(mutations().at(-1)?.action, "navigate", "normal address editing keeps its existing behavior");
});
