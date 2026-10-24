import assert from "node:assert/strict";
import test from "node:test";
import { flushSync } from "svelte";
import type { BridgeInitialStatePayload } from "../lib/bridge/protocol";
import { tab } from "./testFixtures";
import { freshStores, stubBridgeWindow } from "./testHarness";

const spaceId = "space";

async function withOnboarding(activeTab: ReturnType<typeof tab>) {
	stubBridgeWindow({ document: true });
	const loadStore = await freshStores();
	const tabsModule = await loadStore("/src/stores/tabs.svelte.ts");
	const sidebarModule = await loadStore("/src/stores/sidebar.svelte.ts");
	const spacesModule = await loadStore("/src/stores/spaces.svelte.ts");
	const commandBar = await loadStore("/src/stores/commandBar.svelte.ts");
	const onboarding = await loadStore("/src/stores/onboarding.svelte.ts");
	tabsModule.initTabStore();
	commandBar.initCommandBarStore();
	onboarding.initOnboardingStore();

	const initial = {
		activeSpaceId: spaceId,
		activeTabId: activeTab.id,
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [{ id: spaceId, name: "Space", icon: "S", color: "#5865f2", profileId: "profile", isPrivate: false, sortOrder: 0 }],
		tabs: [activeTab],
		treeItems: [],
	} as unknown as BridgeInitialStatePayload;
	spacesModule.applySpaceInitialState(initial);
	sidebarModule.applySidebarTabInitialState(initial);
	const receive = (globalThis as { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } }).window.__lilo!.receive;
	receive({ event: "onboardingState", show: true, step: 0, usage: "browse" });
	flushSync();

	return {
		isOpen: commandBar.isCommandBarOpen as () => boolean,
		finish: onboarding.finishOnboarding as () => void,
	};
}

test("finishing the onboarding on a blank tab opens its command bar", async () => {
	const ctx = await withOnboarding(tab("blank-tab", spaceId, { url: "" }));
	assert.equal(ctx.isOpen(), false);

	ctx.finish();
	flushSync();

	assert.equal(ctx.isOpen(), true);
});

test("finishing the onboarding on a page leaves the command bar closed", async () => {
	const ctx = await withOnboarding(tab("page-tab", spaceId, { url: "https://example.com/" }));

	ctx.finish();
	flushSync();

	assert.equal(ctx.isOpen(), false);
});
