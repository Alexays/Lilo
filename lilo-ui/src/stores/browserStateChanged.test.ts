import assert from "node:assert/strict";
import test from "node:test";
import type {
	BridgeBrowserStateChangedPayload,
	BridgeInitialStatePayload,
	BridgeTabFolderSnapshot,
} from "../lib/bridge/protocol";
import { tab, treeItem } from "./testFixtures";
import { freshStores, stubBridgeWindow } from "./testHarness";

function folder(id: string, spaceId: string): BridgeTabFolderSnapshot {
	return {
		id,
		spaceId,
		name: id,
		color: "#5865f2",
		isCollapsed: false,
	};
}

test("browserStateChanged applies tabs folders active ids and treeItems atomically", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const { applySpaceInitialState } = await loadStore("/src/stores/spaces.svelte.ts");
	const { getActiveTabId, getTabs, initTabStore } =
		await loadStore("/src/stores/tabs.svelte.ts");
	const { getRootItems } = await loadStore("/src/stores/folders.svelte.ts");
	const { applySidebarFolderInitialState, applySidebarTabInitialState } =
		await loadStore("/src/stores/sidebar.svelte.ts");

	const sourceSpaceId = "source-space";
	const targetSpaceId = "target-space";
	const initialState = {
		activeSpaceId: sourceSpaceId,
		activeTabId: "source-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: sourceSpaceId,
				name: "Source",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
			{
				id: targetSpaceId,
				name: "Target",
				icon: "T",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 1,
			},
		],
		tabs: [tab("source-tab", sourceSpaceId)],
		folders: [],
		treeItems: [treeItem("source-tab", sourceSpaceId, 0)],
	} satisfies BridgeInitialStatePayload;
	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);
	applySidebarFolderInitialState(initialState);
	initTabStore();

	const payload = {
		event: "browserStateChanged",
		changedSpaceId: targetSpaceId,
		states: [
			{
				spaceId: sourceSpaceId,
				activeTabId: "source-tab",
				tabs: [tab("source-tab", sourceSpaceId)],
				folders: [],
				treeItems: [treeItem("source-tab", sourceSpaceId, 0)],
			},
			{
				spaceId: targetSpaceId,
				activeTabId: "moving-tab",
				tabs: [
					tab("moving-tab", targetSpaceId, { groupId: "target-folder" }),
					tab("other-tab", targetSpaceId),
				],
				folders: [folder("target-folder", targetSpaceId)],
				treeItems: [
					treeItem("target-folder", targetSpaceId, 0, "unpinned", "folder"),
					treeItem("moving-tab", targetSpaceId, 0, "unpinned", "tab", "target-folder"),
					treeItem("other-tab", targetSpaceId, 1),
				],
			},
		],
	} satisfies BridgeBrowserStateChangedPayload & { event: "browserStateChanged" };

	(
		globalThis as {
			window: {
				__lilo?: {
					receive(msg: Record<string, unknown>): void;
				};
			};
		}
	).window.__lilo?.receive(payload);

	assert.deepEqual(
		getTabs(sourceSpaceId).map((item: { id: string }) => item.id),
		["source-tab"],
	);
	assert.deepEqual(
		getTabs(targetSpaceId).map((item: { id: string }) => item.id),
		["moving-tab", "other-tab"],
	);
	assert.equal(getActiveTabId(targetSpaceId), "moving-tab");
	assert.deepEqual(getRootItems(targetSpaceId, false), [
		{ kind: "folder", id: "target-folder" },
		{ kind: "tab", id: "other-tab" },
	]);
});

test("switching to a space whose active tab is blank opens the command bar", async () => {
	stubBridgeWindow();
	(globalThis as { document?: unknown }).document ??= {
		addEventListener() {},
		removeEventListener() {},
		hidden: false,
	};

	const loadStore = await freshStores();

	const { applySpaceInitialState, initSpaceStore } =
		await loadStore("/src/stores/spaces.svelte.ts");
	const { initTabStore } = await loadStore("/src/stores/tabs.svelte.ts");
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");
	const { initCommandBarStore, isCommandBarOpen } =
		await loadStore("/src/stores/commandBar.svelte.ts");

	const sourceSpaceId = "source-space";
	const targetSpaceId = "target-space";
	const initialState = {
		activeSpaceId: sourceSpaceId,
		activeTabId: "source-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: sourceSpaceId,
				name: "Source",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
			{
				id: targetSpaceId,
				name: "Target",
				icon: "T",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 1,
			},
		],
		tabs: [tab("source-tab", sourceSpaceId)],
		folders: [],
		treeItems: [],
	} satisfies BridgeInitialStatePayload;
	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);
	initTabStore();
	initSpaceStore();
	initCommandBarStore();

	const blankTab = {
		...tab("blank-tab", targetSpaceId),
		url: "",
		title: "New Tab",
	};
	const payload = {
		event: "browserStateChanged",
		changedSpaceId: targetSpaceId,
		transitionId: "transition",
		states: [
			{
				spaceId: targetSpaceId,
				activeTabId: blankTab.id,
				tabs: [blankTab],
				folders: [],
				treeItems: [],
			},
		],
	} satisfies BridgeBrowserStateChangedPayload & { event: "browserStateChanged" };

	(
		globalThis as {
			window: {
				__lilo?: {
					receive(msg: Record<string, unknown>): void;
				};
			};
		}
	).window.__lilo?.receive(payload);

	assert.equal(isCommandBarOpen(), true);
});

test("native browserStateChanged without a pending transition activates the changed space", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const { applySpaceInitialState, getActiveSpaceId, initSpaceStore } =
		await loadStore("/src/stores/spaces.svelte.ts");

	const sourceSpaceId = "source-space";
	const targetSpaceId = "private-space";
	applySpaceInitialState({
		activeSpaceId: sourceSpaceId,
		activeTabId: "source-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: sourceSpaceId,
				name: "Source",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
			{
				id: targetSpaceId,
				name: "Private",
				icon: "🔒",
				color: "#3f4656",
				profileId: "profile",
				isPrivate: true,
				sortOrder: 1,
			},
		],
		tabs: [tab("source-tab", sourceSpaceId)],
		folders: [],
		treeItems: [],
	} satisfies BridgeInitialStatePayload);
	initSpaceStore();

	const payload = {
		event: "browserStateChanged",
		changedSpaceId: targetSpaceId,
		profileId: "profile",
		states: [
			{
				spaceId: targetSpaceId,
				activeTabId: "",
				tabs: [],
				folders: [],
				treeItems: [],
			},
		],
	} satisfies BridgeBrowserStateChangedPayload & { event: "browserStateChanged" };

	(
		globalThis as {
			window: {
				__lilo?: {
					receive(msg: Record<string, unknown>): void;
				};
			};
		}
	).window.__lilo?.receive(payload);

	assert.equal(getActiveSpaceId(), targetSpaceId);
});

test("native browserStateChanged without a pending transition aligns the pager", async () => {
	stubBridgeWindow();
	(globalThis as { requestAnimationFrame?: unknown }).requestAnimationFrame = (
		callback: FrameRequestCallback,
	) => {
		callback(0);
		return 1;
	};
	(globalThis as { cancelAnimationFrame?: unknown }).cancelAnimationFrame = () => {};
	(globalThis as { ResizeObserver?: unknown }).ResizeObserver = class {
		observe() {}
		disconnect() {}
	};

	const loadStore = await freshStores();

	const { applySpaceInitialState, initSpaceStore } =
		await loadStore("/src/stores/spaces.svelte.ts");
	const { initPagerStore, setSpacePagerElement } =
		await loadStore("/src/stores/pager.svelte.ts");

	const sourceSpaceId = "source-space";
	const targetSpaceId = "private-space";
	applySpaceInitialState({
		activeSpaceId: sourceSpaceId,
		activeTabId: "source-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: sourceSpaceId,
				name: "Source",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
			{
				id: targetSpaceId,
				name: "Private",
				icon: "🔒",
				color: "#3f4656",
				profileId: "profile",
				isPrivate: true,
				sortOrder: 1,
			},
		],
		tabs: [tab("source-tab", sourceSpaceId)],
		folders: [],
		treeItems: [],
	} satisfies BridgeInitialStatePayload);
	initSpaceStore();
	initPagerStore();

	const pagerElement = {
		clientWidth: 320,
		scrollLeft: 0,
		style: { scrollBehavior: "" },
		addEventListener() {},
		removeEventListener() {},
		scrollTo({ left }: { left: number }) {
			this.scrollLeft = left;
		},
	};
	setSpacePagerElement(pagerElement as unknown as HTMLDivElement);

	const payload = {
		event: "browserStateChanged",
		changedSpaceId: targetSpaceId,
		profileId: "profile",
		states: [
			{
				spaceId: targetSpaceId,
				activeTabId: "",
				tabs: [],
				folders: [],
				treeItems: [],
			},
		],
	} satisfies BridgeBrowserStateChangedPayload & { event: "browserStateChanged" };

	(
		globalThis as {
			window: {
				__lilo?: {
					receive(msg: Record<string, unknown>): void;
				};
			};
		}
	).window.__lilo?.receive(payload);

	assert.equal(pagerElement.scrollLeft, 320);
});

test("a space created and shown in one batch gets the pager once its page is laid out", async () => {
	stubBridgeWindow();
	const frames: FrameRequestCallback[] = [];
	(globalThis as { requestAnimationFrame?: unknown }).requestAnimationFrame = (
		callback: FrameRequestCallback,
	) => frames.push(callback);
	(globalThis as { cancelAnimationFrame?: unknown }).cancelAnimationFrame = () => {};
	(globalThis as { ResizeObserver?: unknown }).ResizeObserver = class {
		observe() {}
		disconnect() {}
	};

	const loadStore = await freshStores();
	const { applySpaceInitialState, initSpaceStore } =
		await loadStore("/src/stores/spaces.svelte.ts");
	const { initPagerStore, setSpacePagerElement } =
		await loadStore("/src/stores/pager.svelte.ts");

	const space = (id: string, sortOrder: number, isPrivate = false) => ({
		id,
		name: id,
		icon: "S",
		color: "#5865f2",
		profileId: "profile",
		isPrivate,
		sortOrder,
	});
	applySpaceInitialState({
		activeSpaceId: "home",
		activeTabId: "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [space("home", 0), space("work", 1)],
		tabs: [],
		folders: [],
		treeItems: [],
	} satisfies BridgeInitialStatePayload);
	initSpaceStore();
	initPagerStore();

	// A scroll track clamps to the pages it has laid out, and the new space's page only comes
	// with the next render.
	let laidOutPages = 2;
	let left = 0;
	const pagerElement = {
		clientWidth: 320,
		get scrollLeft() {
			return left;
		},
		set scrollLeft(value: number) {
			left = Math.min(value, (laidOutPages - 1) * 320);
		},
		style: { scrollBehavior: "" },
		addEventListener() {},
		removeEventListener() {},
		scrollTo({ left }: { left: number }) {
			this.scrollLeft = left;
		},
	};
	setSpacePagerElement(pagerElement as unknown as HTMLDivElement);
	frames.splice(0);

	const receive = (globalThis as { window: { __lilo: { receiveBatch(msgs: unknown[]): void } } })
		.window.__lilo.receiveBatch;
	receive([
		{ event: "spaceCreated", ...space("private", 2, true) },
		{
			event: "browserStateChanged",
			changedSpaceId: "private",
			profileId: "profile",
			states: [{ spaceId: "private", activeTabId: "", tabs: [], folders: [], treeItems: [] }],
		},
	]);
	laidOutPages = 3;
	for (let frame = 0; frame < 10 && frames.length > 0; frame++) {
		for (const callback of frames.splice(0)) callback(0);
	}

	assert.equal(pagerElement.scrollLeft, 640);
});

test("native browserStateChanged during a user swipe does not snap the pager early", async () => {
	const postedMessages: Array<{ action: string; payload: Record<string, unknown> }> = [];
	(globalThis as { window?: unknown }).window = {
		__liloBootstrapEvents: [],
		webkit: {
			messageHandlers: {
				lilo: {
					postMessage(message: { action: string; payload: Record<string, unknown> }) {
						postedMessages.push(message);
					},
				},
			},
		},
	};
	(globalThis as { requestAnimationFrame?: unknown }).requestAnimationFrame = (
		callback: FrameRequestCallback,
	) => {
		callback(0);
		return 1;
	};
	(globalThis as { cancelAnimationFrame?: unknown }).cancelAnimationFrame = () => {};
	(globalThis as { ResizeObserver?: unknown }).ResizeObserver = class {
		observe() {}
		disconnect() {}
	};
	(globalThis as { document?: unknown }).document = {
		documentElement: {
			classList: {
				contains() {
					return false;
				},
			},
		},
	};

	const loadStore = await freshStores();

	const { applySpaceInitialState, initSpaceStore } =
		await loadStore("/src/stores/spaces.svelte.ts");
	const { getSpacePagerVirtualIndex, initPagerStore, setSpacePagerElement } =
		await loadStore("/src/stores/pager.svelte.ts");

	const sourceSpaceId = "source-space";
	const targetSpaceId = "target-space";
	applySpaceInitialState({
		activeSpaceId: sourceSpaceId,
		activeTabId: "source-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: sourceSpaceId,
				name: "Source",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
			{
				id: targetSpaceId,
				name: "Target",
				icon: "T",
				color: "#3f4656",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 1,
			},
		],
		tabs: [tab("source-tab", sourceSpaceId)],
		folders: [],
		treeItems: [],
	} satisfies BridgeInitialStatePayload);
	initSpaceStore();
	initPagerStore();

	const listeners = new Map<string, EventListener>();
	const pagerElement = {
		clientWidth: 320,
		scrollLeft: 0,
		onscrollend: null,
		style: { scrollBehavior: "" },
		addEventListener(type: string, listener: EventListener) {
			listeners.set(type, listener);
		},
		removeEventListener() {},
		scrollTo({ left }: { left: number }) {
			this.scrollLeft = left;
		},
	};
	setSpacePagerElement(pagerElement as unknown as HTMLDivElement);

	pagerElement.scrollLeft = 170;
	listeners.get("scroll")?.(new Event("scroll"));

	const switchMessage = postedMessages.find(
		(message) => message.action === "switchSpace",
	);
	assert.equal(switchMessage?.payload.id, targetSpaceId);
	const transitionId = String(switchMessage?.payload.transitionId ?? "");
	assert.notEqual(transitionId, "");

	const payload = {
		event: "browserStateChanged",
		changedSpaceId: targetSpaceId,
		transitionId,
		states: [
			{
				spaceId: targetSpaceId,
				activeTabId: "",
				tabs: [],
				folders: [],
				treeItems: [],
			},
		],
	} satisfies BridgeBrowserStateChangedPayload & { event: "browserStateChanged" };

	(
		globalThis as {
			window: {
				__lilo?: {
					receive(msg: Record<string, unknown>): void;
				};
			};
		}
	).window.__lilo?.receive(payload);

	assert.equal(pagerElement.scrollLeft, 170);
	assert.equal(getSpacePagerVirtualIndex().toFixed(3), "0.531");
});

test("full state without favicons keeps the favicons the store already holds", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();

	const { applySpaceInitialState } = await loadStore("/src/stores/spaces.svelte.ts");
	const { getTabs, initTabStore } = await loadStore("/src/stores/tabs.svelte.ts");
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");

	const sourceSpaceId = "source-space";
	const targetSpaceId = "target-space";
	const initialState = {
		activeSpaceId: sourceSpaceId,
		activeTabId: "kept-tab",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: sourceSpaceId,
				name: "Source",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
			{
				id: targetSpaceId,
				name: "Target",
				icon: "T",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 1,
			},
		],
		tabs: [
			tab("kept-tab", sourceSpaceId, {
				faviconDataURL: "data:image/png;base64,kept",
			}),
			tab("refreshed-tab", sourceSpaceId, {
				faviconDataURL: "data:image/png;base64,old",
			}),
			tab("moving-tab", sourceSpaceId, {
				faviconDataURL: "data:image/png;base64,moving",
			}),
		],
		folders: [],
		treeItems: [
			treeItem("kept-tab", sourceSpaceId, 0),
			treeItem("refreshed-tab", sourceSpaceId, 1),
			treeItem("moving-tab", sourceSpaceId, 2),
		],
	} satisfies BridgeInitialStatePayload;
	applySpaceInitialState(initialState);
	applySidebarTabInitialState(initialState);
	initTabStore();

	// The host omits faviconDataURL for spaces the chrome already holds; a tab that DID change
	// its favicon ships the fresh value, and a cross-space move relocates the snapshot without one.
	const payload = {
		event: "browserStateChanged",
		changedSpaceId: targetSpaceId,
		states: [
			{
				spaceId: sourceSpaceId,
				activeTabId: "kept-tab",
				tabs: [
					tab("kept-tab", sourceSpaceId),
					tab("refreshed-tab", sourceSpaceId, {
						faviconDataURL: "data:image/png;base64,new",
					}),
				],
				folders: [],
				treeItems: [
					treeItem("kept-tab", sourceSpaceId, 0),
					treeItem("refreshed-tab", sourceSpaceId, 1),
				],
			},
			{
				spaceId: targetSpaceId,
				activeTabId: "moving-tab",
				tabs: [tab("moving-tab", targetSpaceId)],
				folders: [],
				treeItems: [treeItem("moving-tab", targetSpaceId, 0)],
			},
		],
	} satisfies BridgeBrowserStateChangedPayload & { event: "browserStateChanged" };

	(
		globalThis as {
			window: {
				__lilo?: {
					receive(msg: Record<string, unknown>): void;
				};
			};
		}
	).window.__lilo?.receive(payload);

	const sourceFavicons = Object.fromEntries(
		getTabs(sourceSpaceId).map((t: { id: string; faviconDataURL?: string }) => [
			t.id,
			t.faviconDataURL,
		]),
	);
	assert.equal(sourceFavicons["kept-tab"], "data:image/png;base64,kept");
	assert.equal(sourceFavicons["refreshed-tab"], "data:image/png;base64,new");
	assert.equal(
		getTabs(targetSpaceId).find((t: { id: string }) => t.id === "moving-tab")
			?.faviconDataURL,
		"data:image/png;base64,moving",
	);
});
