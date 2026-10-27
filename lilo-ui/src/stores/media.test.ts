import assert from "node:assert/strict";
import test from "node:test";
import type { BridgeCallTab, BridgeInitialStatePayload, BridgeMediaTab } from "../lib/bridge/protocol";
import { tab, treeItem } from "./testFixtures";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

function media(...tabs: Partial<BridgeMediaTab>[]): void {
	activity(tabs, []);
}

function activity(tabs: Partial<BridgeMediaTab>[], calls: Partial<BridgeCallTab>[]): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive({
		event: "mediaActivity",
		calls: calls.map((entry) => ({
			id: "",
			spaceId: "space",
			title: "",
			faviconDataURL: "",
			hasMicrophone: true,
			microphoneMuted: false,
			hasCamera: false,
			cameraOff: true,
			canHangUp: false,
			...entry,
		})),
		tabs: tabs.map((entry) => ({
			id: "",
			spaceId: "space",
			title: "",
			faviconDataURL: "",
			playing: true,
			muted: false,
			hasTrackControls: false,
			...entry,
		})),
	});
}

async function loadMediaStore() {
	const loadStore = await freshStores();
	const state = {
		activeSpaceId: "space",
		activeTabId: "shown",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: "space", name: "Space", icon: "S", color: "#5865f2", profileId: "profile", isPrivate: false, sortOrder: 0 }],
		tabs: [tab("shown", "space"), tab("music", "space")],
		treeItems: [treeItem("shown", "space", 0), treeItem("music", "space", 1)],
	} satisfies BridgeInitialStatePayload;
	(await loadStore("/src/stores/spaces.svelte.ts")).applySpaceInitialState(state);
	(await loadStore("/src/stores/sidebar.svelte.ts")).applySidebarTabInitialState(state);
	const store = await loadStore("/src/stores/media.svelte.ts");
	store.initMediaStore();
	return store;
}

test("the card asks for the media tabs and hides while nothing plays", async () => {
	const posted = stubBridgeWindow();
	const store = await loadMediaStore();

	assert.ok(posted.some((message) => message.action === "getMediaActivity"));
	assert.equal(store.getMediaCardTab(), undefined);
	media();
	assert.equal(store.getMediaCardTab(), undefined);
});

test("the card hides when the only media plays in the shown tab", async () => {
	stubBridgeWindow();
	const store = await loadMediaStore();

	media({ id: "shown" });
	assert.equal(store.getMediaCardTab(), undefined);
});

test("the card shows media playing in another tab, ahead of one paused from it", async () => {
	stubBridgeWindow();
	const store = await loadMediaStore();

	media({ id: "paused", playing: false });
	assert.equal(store.getMediaCardTab()?.id, "paused");
	media({ id: "paused", playing: false }, { id: "music" }, { id: "shown" });
	assert.equal(store.getMediaCardTab()?.id, "music");
});

test("a call keeps its card while shown and leaves its sound to it", async () => {
	stubBridgeWindow();
	const store = await loadMediaStore();

	activity([{ id: "music" }], [{ id: "music" }]);
	assert.equal(store.getCallCardTab()?.id, "music");
	assert.equal(store.getMediaCardTab(), undefined);

	activity([{ id: "music" }], [{ id: "shown" }]);
	assert.equal(store.getCallCardTab()?.id, "shown");
	assert.equal(store.getMediaCardTab()?.id, "music");
});
