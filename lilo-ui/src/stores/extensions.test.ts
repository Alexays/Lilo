import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

test("a private space shows only the extensions allowed there", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const spaces = await loadStore("/src/stores/spaces.svelte.ts");
	const extensions = await loadStore("/src/stores/extensions.svelte.ts");
	extensions.initExtensionStore();
	const space = (id: string, isPrivate: boolean) => ({
		id, name: id, icon: "S", color: "#5865f2", profileId: "profile", isPrivate, sortOrder: isPrivate ? 1 : 0,
	});
	spaces.applySpaceInitialState({
		activeSpaceId: "home", activeTabId: "", sidebarWidth: 0, sidebarVisible: true,
		spaces: [space("home", false), space("private", true)], tabs: [], treeItems: [],
	});
	(globalThis as unknown as { window: { __lilo: { receive(msg: Record<string, unknown>): void } } }).window.__lilo.receive({
		event: "extensionsChanged",
		ids: ["blocked", "allowed"],
		extensions: [{ id: "blocked", isEnabled: true }, { id: "allowed", isEnabled: true, allowsPrivateAccess: true }],
	});
	const shown = () => extensions.getEnabledExtensions().map((e: { id: string }) => e.id);

	assert.deepEqual(shown(), ["blocked", "allowed"]);
	spaces.applySpaceInitialState({
		activeSpaceId: "private", activeTabId: "", sidebarWidth: 0, sidebarVisible: true,
		spaces: [space("home", false), space("private", true)], tabs: [], treeItems: [],
	});
	assert.deepEqual(shown(), ["allowed"]);
});
