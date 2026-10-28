import assert from "node:assert/strict";
import test from "node:test";
import { flushSync } from "svelte";
import type { BridgeInitialStatePayload } from "../lib/bridge/protocol";
import { tab } from "./testFixtures";
import { freshStores, stubBridgeWindow } from "./testHarness";

async function withBar(settings: Record<string, string> = {}) {
	const sent = stubBridgeWindow({ document: true });
	const loadStore = await freshStores();
	const tabs = await loadStore("/src/stores/tabs.svelte.ts");
	const sidebar = await loadStore("/src/stores/sidebar.svelte.ts");
	const spaces = await loadStore("/src/stores/spaces.svelte.ts");
	const settingsStore = await loadStore("/src/stores/settings.svelte.ts");
	const bar = await loadStore("/src/stores/commandBar.svelte.ts");
	tabs.initTabStore();
	settingsStore.initSettingsStore();
	bar.initCommandBarStore();

	const initial = {
		activeSpaceId: "home",
		activeTabId: "blank",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: "home", name: "Home", icon: "🏠", color: "#5865f2", profileId: "personal", isPrivate: false, sortOrder: 0 }],
		profiles: [{ id: "personal", name: "Personal", isDefault: true }],
		tabs: [tab("blank", "home", { title: "New Tab", url: "" })],
		treeItems: [],
	} as unknown as BridgeInitialStatePayload;
	spaces.applySpaceInitialState(initial);
	sidebar.applySidebarTabInitialState(initial);
	flushSync();

	const receive = (
		globalThis as { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } }
	).window.__lilo!.receive;
	receive({ event: "settingsLoaded", settings });
	const preloads = () => sent.filter((message) => message.action === "preloadTopHit").map((message) => message.payload.url);
	return { bar, receive, preloads };
}

const video = (visitCount: number) => ({
	id: "1", title: "Videos", url: "https://www.videos.example/", visitCount, lastVisitedAt: Date.now(),
});

test("a site visited often preloads while its address is typed, and is dropped when the bar closes", async () => {
	const { bar, receive, preloads } = await withBar();
	bar.openCommandBar("", true);
	bar.setQuery("vid");
	receive({ event: "historyResults", query: "vid", results: [video(12)] });

	assert.deepEqual(preloads(), ["https://www.videos.example/"]);
	bar.setQuery("vide");
	receive({ event: "historyResults", query: "vide", results: [video(12)] });
	assert.deepEqual(preloads(), ["https://www.videos.example/"], "the same top hit is not asked for again");

	bar.executeSelected();
	assert.deepEqual(preloads(), ["https://www.videos.example/", ""]);
});

test("no preload for a site seen once, a search, a page matched by its title, or with the setting off", async () => {
	const rare = await withBar();
	rare.bar.openCommandBar("");
	rare.bar.setQuery("vid");
	rare.receive({ event: "historyResults", query: "vid", results: [video(1)] });
	assert.deepEqual(rare.preloads(), []);

	const search = await withBar();
	search.bar.openCommandBar("");
	search.bar.setQuery("weather tomorrow");
	search.receive({ event: "historyResults", query: "weather tomorrow", results: [] });
	assert.deepEqual(search.preloads(), []);

	const title = await withBar();
	title.bar.openCommandBar("");
	title.bar.setQuery("videos");
	title.receive({ event: "historyResults", query: "videos", results: [
		{ id: "2", title: "Videos", url: "https://watch.example/", visitCount: 12, lastVisitedAt: Date.now() },
	] });
	assert.deepEqual(title.preloads(), []);

	const off = await withBar({ preloadTopHit: "false" });
	off.bar.openCommandBar("");
	off.bar.setQuery("vid");
	off.receive({ event: "historyResults", query: "vid", results: [video(12)] });
	assert.deepEqual(off.preloads(), []);
});

test("typing on past the top hit drops its preload", async () => {
	const { bar, receive, preloads } = await withBar();
	bar.openCommandBar("");
	bar.setQuery("vid");
	receive({ event: "historyResults", query: "vid", results: [video(12)] });
	bar.setQuery("vidx");
	receive({ event: "historyResults", query: "vidx", results: [] });

	assert.deepEqual(preloads(), ["https://www.videos.example/", ""]);
});
