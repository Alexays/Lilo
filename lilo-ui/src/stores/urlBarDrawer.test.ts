import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = {
	window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

function receive(msg: Record<string, unknown>): void {
	(globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

async function loadDrawerStore() {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const tabs = await loadStore("/src/stores/tabs.svelte.ts");
	const drawer = await loadStore("/src/stores/urlBarDrawer.svelte.ts");
	drawer.initUrlBarDrawerStore();
	return { posted, drawer, activeTabId: tabs.getActiveTabId() as string };
}

test("a site request outranks the invite, which outranks the Site drawer", async () => {
	const { drawer, activeTabId } = await loadDrawerStore();

	drawer.setSiteDrawerOpen(true);
	assert.equal(drawer.getActiveUrlBarDrawer()?.kind, "site");

	receive({ event: "defaultBrowserStatusLoaded", isDefault: false, shouldInvite: true });
	assert.equal(drawer.getActiveUrlBarDrawer()?.kind, "defaultBrowser");

	receive({ event: "permissionRequest", requestId: "r1", tabId: activeTabId, type: "camera", origin: "meet.example.com" });
	assert.equal(drawer.getActiveUrlBarDrawer()?.kind, "sitePermission");
});

test("a request for another tab waits until that tab is active", async () => {
	const { drawer } = await loadDrawerStore();

	receive({ event: "permissionRequest", requestId: "r1", tabId: "some-other-tab", type: "camera", origin: "a.example" });
	assert.equal(drawer.getActiveUrlBarDrawer(), null);
});

test("answering a request replies to the host and does not reopen the Site drawer", async () => {
	const { posted, drawer, activeTabId } = await loadDrawerStore();

	drawer.setSiteDrawerOpen(true);
	receive({ event: "permissionRequest", requestId: "r1", tabId: activeTabId, type: "microphone", origin: "a.example" });
	drawer.respondToPermissionRequest(drawer.getActiveUrlBarDrawer(), true);

	assert.deepEqual(posted.at(-1), { action: "permissionResponse", payload: { requestId: "r1", granted: true } });
	assert.equal(drawer.getActiveUrlBarDrawer(), null);
	assert.equal(drawer.isSiteDrawerOpen(), false);
});

test("a request the host closed leaves the queue", async () => {
	const { drawer, activeTabId } = await loadDrawerStore();

	receive({ event: "permissionRequest", requestId: "r1", tabId: activeTabId, type: "camera", origin: "a.example" });
	receive({ event: "permissionRequestClosed", requestId: "r1" });
	assert.equal(drawer.getActiveUrlBarDrawer(), null);
});

test("a stored allowlist that is not a list allows no site", async () => {
	const { drawer } = await loadDrawerStore();

	receive({ event: "settingsLoaded", settings: { contentBlockerAllowlist: "{}" } });

	assert.equal(drawer.isBlockerAllowlisted("example.com"), false);
});
