import assert from "node:assert/strict";
import test from "node:test";
import { flushSync } from "svelte";
import type { BridgeInitialStatePayload } from "../lib/bridge/protocol";
import { tab } from "./testFixtures";
import { freshStores, stubBridgeWindow } from "./testHarness";

async function withBar() {
	const sent = stubBridgeWindow({ document: true });
	const loadStore = await freshStores();
	const tabs = await loadStore("/src/stores/tabs.svelte.ts");
	const sidebar = await loadStore("/src/stores/sidebar.svelte.ts");
	const spaces = await loadStore("/src/stores/spaces.svelte.ts");
	const profiles = await loadStore("/src/stores/profiles.svelte.ts");
	const bar = await loadStore("/src/stores/commandBar.svelte.ts");
	tabs.initTabStore();
	bar.initCommandBarStore();

	const initial = {
		activeSpaceId: "home",
		activeTabId: "active",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{ id: "home", name: "Home", icon: "🏠", color: "#5865f2", profileId: "personal", isPrivate: false, sortOrder: 0 },
			{ id: "work", name: "Work", icon: "💼", color: "#5865f2", profileId: "job", isPrivate: false, sortOrder: 1 },
		],
		profiles: [
			{ id: "personal", name: "Personal", isDefault: true },
			{ id: "job", name: "Acme", isDefault: false },
		],
		tabs: [
			tab("active", "home", { title: "Active", url: "https://active.example/" }),
			tab("docs", "home", { title: "Docs", url: "https://docs.example/" }),
			tab("mail", "home", { title: "Mail", url: "https://mail.example/" }),
			tab("waybar", "home", { title: "Waybar", url: "https://github.com/Alexays/Waybar" }),
		],
		treeItems: [],
	} as unknown as BridgeInitialStatePayload;
	spaces.applySpaceInitialState(initial);
	profiles.applyProfileInitialState(initial);
	sidebar.applySidebarTabInitialState(initial);
	flushSync();

	const receive = (
		globalThis as { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } }
	).window.__lilo!.receive;
	const last = (action: string) => sent.filter((message) => message.action === action).at(-1)?.payload;
	return { sent, bar, receive, last };
}

test("a tab row answers split, peek, copy, close and move; Option+Return splits it beside the current tab", async () => {
	const { bar, last } = await withBar();
	bar.openCommandBar("@docs");

	assert.equal(bar.getSelectedResult()?.id, "tab-docs");
	assert.deepEqual(bar.getSelectedResultKeys(), ["newTab", "split", "peek", "copy", "close", "move"]);
	assert.equal(bar.runSelectedResultKey("remove"), false, "a tab row is closed, not removed from history");

	assert.equal(bar.runSelectedResultKey("split"), true);
	assert.deepEqual(last("splitTab"), { tabId: "docs", side: "right", targetTabId: undefined });
	assert.equal(bar.isCommandBarOpen(), false);
});

test("Shift+Return peeks a history row; Cmd+Backspace removes it from history, never closes a tab", async () => {
	const { bar, receive, last } = await withBar();
	bar.openCommandBar("/rust");
	receive({ event: "historyResults", query: "rust", results: [
		{ id: "1", title: "Rust", url: "https://rust.example/", visitCount: 2, lastVisitedAt: Date.now() },
	] });

	assert.deepEqual(bar.getSelectedResultKeys(), ["newTab", "split", "peek", "copy", "remove"]);
	assert.equal(bar.runSelectedResultKey("close"), false);
	assert.equal(bar.runSelectedResultKey("move"), false);

	assert.equal(bar.runSelectedResultKey("remove"), true);
	assert.deepEqual(last("deleteHistoryEntry"), { url: "https://rust.example/", query: "/rust" });

	assert.equal(bar.runSelectedResultKey("peek"), true);
	assert.deepEqual(last("peekURL"), { url: "https://rust.example/" });
	assert.equal(bar.isCommandBarOpen(), false);
});

test("Option+Return on a typed address opens it in a split; an action row takes none of the row keys", async () => {
	const { bar, last } = await withBar();
	bar.openCommandBar("example.org");
	assert.equal(bar.getSelectedResult()?.kind, "navigate");
	assert.equal(bar.runSelectedResultKey("split"), true);
	assert.deepEqual(last("splitURL"), { url: "https://example.org", side: "right", targetTabId: undefined });

	bar.openCommandBar(":reload");
	assert.equal(bar.getSelectedResult()?.kind, "action");
	assert.deepEqual(bar.getSelectedResultKeys(), []);
	for (const key of ["split", "peek", "copy", "close", "remove", "move"]) {
		assert.equal(bar.runSelectedResultKey(key), false, key);
	}
	assert.equal(bar.isCommandBarOpen(), true);
});

test("Cmd+Backspace closes the selected tab in place and the next row takes the selection", async () => {
	const { bar, last } = await withBar();
	bar.openCommandBar("@");
	assert.deepEqual(bar.getResults().map((result: { id: string }) => result.id), ["tab-docs", "tab-mail", "tab-waybar"]);

	assert.equal(bar.runSelectedResultKey("close"), true);
	assert.deepEqual(last("closeTab"), { id: "docs" });
	assert.equal(bar.isCommandBarOpen(), true);
	assert.deepEqual(bar.getResults().map((result: { id: string }) => result.id), ["tab-mail", "tab-waybar"]);
	assert.deepEqual(bar.getSections()[0].items.map((entry: { index: number }) => entry.index), [0, 1]);
	assert.equal(bar.getSelectedResult()?.id, "tab-mail");
});

test("Cmd+M on a tab row picks a Space to move it to; Escape goes back to the query", async () => {
	const { bar, last } = await withBar();
	bar.openCommandBar("@docs");

	assert.equal(bar.runSelectedResultKey("move"), true);
	assert.equal(bar.isMovingTab(), true);
	assert.deepEqual(bar.getResults().map(({ kind, title, subtitle, icon }: Record<string, string>) => ({ kind, title, subtitle, icon })), [
		{ kind: "moveToSpace", title: "Work", subtitle: "Acme", icon: "💼" },
	]);
	assert.deepEqual(bar.getSelectedResultKeys(), []);

	bar.cancelMoveTab();
	assert.equal(bar.isMovingTab(), false);
	assert.equal(bar.getQuery(), "@docs");

	bar.runSelectedResultKey("move");
	bar.executeSelected();
	assert.deepEqual(last("moveTabToSpace"), { tabId: "docs", spaceId: "work" });
	assert.equal(bar.isCommandBarOpen(), false);
	assert.equal(bar.isMovingTab(), false);
});

test("Cmd+C copies the selected row's address", async () => {
	const { bar } = await withBar();
	const copied: string[] = [];
	Object.defineProperty(globalThis.navigator, "clipboard", {
		configurable: true,
		value: { writeText: async (text: string) => void copied.push(text) },
	});
	bar.openCommandBar("@mail");

	assert.equal(bar.runSelectedResultKey("copy"), true);
	await Promise.resolve();
	assert.deepEqual(copied, ["https://mail.example/"]);
	assert.equal(bar.isCommandBarOpen(), false);
});

test("a Space row switches to it, and a Move row moves the current tab", async () => {
	const { bar, last } = await withBar();
	bar.openCommandBar(":work");
	const rows = bar.getResults().filter((result: { kind: string }) => result.kind === "space" || result.kind === "moveToSpace");

	bar.executeResult(rows[0]);
	assert.deepEqual(last("switchSpace"), { id: "work", transitionId: undefined });

	bar.openCommandBar(":work");
	bar.executeResult(rows[1]);
	assert.deepEqual(last("moveTabToSpace"), { tabId: "active", spaceId: "work" });
});

test("the selection stays on the top row while history arrives, unless the user picked another row", async () => {
	const { bar, receive } = await withBar();
	const news = [{ id: "n", title: "Hacker News", url: "https://news.ycombinator.com/", visitCount: 50, lastVisitedAt: Date.now() }];

	bar.openCommandBar("news");
	assert.equal(bar.getSelectedResult()?.kind, "search");
	receive({ event: "historyResults", query: "news", results: news });
	assert.equal(bar.getSelectedIndex(), 0);
	assert.equal(bar.getSelectedResult()?.title, "Hacker News", "Enter opens what the top row shows");

	bar.openCommandBar("news");
	bar.selectNext();
	const picked = bar.getSelectedResult()?.id;
	receive({ event: "historyResults", query: "news", results: news });
	assert.equal(bar.getSelectedResult()?.id, picked);
});

test("over a local top row, the ghost text only names the site root that row opens", async () => {
	const { bar } = await withBar();

	bar.openCommandBar("doc");
	assert.equal(bar.getSelectedResult()?.id, "tab-docs");
	assert.equal(bar.getAutocompleteSuggestion(), "docs.example");

	bar.openCommandBar("gith");
	assert.equal(bar.getAutocompleteSuggestion(), "");
});

test("a search suggestion never puts ghost text over a top row that does something else", async () => {
	const { bar, receive } = await withBar();
	bar.openCommandBar("zebr");
	receive({ event: "searchSuggestions", query: "zebr", suggestions: ["zebra crossing"] });

	assert.equal(bar.getSelectedResult()?.kind, "search");
	assert.equal(bar.getAutocompleteSuggestion(), "");
});

test("a site the query starts leads, and its ghost text and Enter both go there", async () => {
	const { bar, receive, last } = await withBar();
	bar.openCommandBar("wiki");
	receive({ event: "historyResults", query: "wiki", results: [
		{ id: "w", title: "Wikipedia", url: "https://wikipedia.org/", visitCount: 30, lastVisitedAt: Date.now() },
	] });

	assert.equal(bar.getSelectedResult()?.title, "Wikipedia");
	assert.equal(bar.getAutocompleteSuggestion(), "wikipedia.org");
	bar.executeSelected();
	assert.deepEqual(last("navigate"), { url: "https://wikipedia.org/", typed: false });
});
