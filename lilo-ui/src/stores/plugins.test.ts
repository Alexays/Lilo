import assert from "node:assert/strict";
import test, { mock } from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

type LiloWindow = { window: { __lilo: { receive(msg: Record<string, unknown>): void } } };
const receive = (msg: Record<string, unknown>): void => (globalThis as unknown as LiloWindow).window.__lilo.receive(msg);

const plugin = (id: string, overrides: Record<string, unknown> = {}) => ({
	id, title: id, version: "1.0.0", enabled: false, running: false, capabilities: [], grantedCapabilities: [],
	settings: [], settingValues: {}, supportDir: `/Users/example/Plugins/${id}`, ...overrides,
});

async function setup() {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const store = await loadStore("/src/stores/plugins.svelte.ts");
	return { posted, store };
}

test("the list is empty and not loaded until the host answers", async () => {
	const { posted, store } = await setup();
	assert.equal(store.arePluginsLoaded(), false);
	store.loadPlugins();
	assert.deepEqual(posted, [{ action: "getPlugins", payload: {} }]);

	receive({ event: "pluginsChanged", plugins: [] });
	assert.equal(store.arePluginsLoaded(), true);
	assert.deepEqual(store.getPlugins(), []);
});

test("every pluginsChanged replaces the list, dropping rows without an id", async () => {
	const { store } = await setup();
	receive({ event: "pluginsChanged", plugins: [plugin("a"), plugin("b")] });
	assert.deepEqual(store.getPlugins().map((row: { id: string }) => row.id), ["a", "b"]);

	receive({ event: "pluginsChanged", plugins: [plugin("b"), { title: "No id" }] });
	assert.deepEqual(store.getPlugins().map((row: { id: string }) => row.id), ["b"]);
	assert.equal(store.getPlugin("a"), undefined);
});

test("enabling waits for the host: the switch is pending until the list confirms it", async () => {
	const { posted, store } = await setup();
	receive({ event: "pluginsChanged", plugins: [plugin("a")] });

	store.setPluginEnabled("a", true);
	assert.deepEqual(posted, [{ action: "setPluginEnabled", payload: { id: "a", enabled: true } }]);
	assert.equal(store.isPluginPending("a"), true);
	assert.equal(store.getPlugin("a").enabled, false);

	// A second tap while pending sends nothing.
	store.setPluginEnabled("a", false);
	assert.equal(posted.length, 1);

	// Another plugin's change is not the answer.
	receive({ event: "pluginsChanged", plugins: [plugin("a"), plugin("b", { running: true })] });
	assert.equal(store.isPluginPending("a"), true);

	receive({ event: "pluginsChanged", plugins: [plugin("a", { enabled: true, running: true }), plugin("b")] });
	assert.equal(store.isPluginPending("a"), false);
	assert.equal(store.getPlugin("a").enabled, true);
});

test("disabling goes back the same way, and asking for the state a plugin has sends nothing", async () => {
	const { posted, store } = await setup();
	receive({ event: "pluginsChanged", plugins: [plugin("a", { enabled: true, running: true })] });

	store.setPluginEnabled("a", true);
	assert.deepEqual(posted, []);

	store.setPluginEnabled("a", false);
	assert.deepEqual(posted, [{ action: "setPluginEnabled", payload: { id: "a", enabled: false } }]);
	receive({ event: "pluginsChanged", plugins: [plugin("a")] });
	assert.equal(store.isPluginPending("a"), false);
	assert.equal(store.getPlugin("a").enabled, false);
});

test("a host that never answers leaves the switch where it was after 8 s", async () => {
	const { store } = await setup();
	receive({ event: "pluginsChanged", plugins: [plugin("a")] });
	mock.timers.enable({ apis: ["setTimeout"] });
	try {
		store.setPluginEnabled("a", true);
		mock.timers.tick(7999);
		assert.equal(store.isPluginPending("a"), true);
		mock.timers.tick(1);
		assert.equal(store.isPluginPending("a"), false);
		assert.equal(store.getPlugin("a").enabled, false);
	} finally {
		mock.timers.reset();
	}
});

test("a plugin removed from its folder settles its wait", async () => {
	const { store } = await setup();
	receive({ event: "pluginsChanged", plugins: [plugin("a")] });
	store.setPluginEnabled("a", true);
	receive({ event: "pluginsChanged", plugins: [] });
	assert.equal(store.isPluginPending("a"), false);
});

test("settings, revocation, Finder and Stop go to the host under the contract's names", async () => {
	const { posted, store } = await setup();
	store.setPluginSetting("a", "interval", "1h");
	store.setPluginSetting("a", "retries", 3);
	store.setPluginSetting("a", "notify", true);
	store.revokePluginCapability("a", "tabs:read");
	store.showPluginInFinder("a");
	store.stopPlugin("a");
	assert.deepEqual(posted, [
		{ action: "setPluginSetting", payload: { id: "a", name: "interval", value: "1h" } },
		{ action: "setPluginSetting", payload: { id: "a", name: "retries", value: 3 } },
		{ action: "setPluginSetting", payload: { id: "a", name: "notify", value: true } },
		{ action: "revokePluginCapability", payload: { id: "a", capability: "tabs:read" } },
		{ action: "showPluginInFinder", payload: { id: "a" } },
		{ action: "stopPlugin", payload: { id: "a" } },
	]);
});

test("a revocation shows once the host reports it: the capability stays asked for, no longer granted", async () => {
	const { store } = await setup();
	const granted = plugin("a", { enabled: true, capabilities: ["tabs:read", "schedule"], grantedCapabilities: ["tabs:read", "schedule"] });
	receive({ event: "pluginsChanged", plugins: [granted] });
	store.revokePluginCapability("a", "tabs:read");
	assert.deepEqual(store.getPlugin("a").grantedCapabilities, ["tabs:read", "schedule"]);

	receive({ event: "pluginsChanged", plugins: [{ ...granted, grantedCapabilities: ["schedule"] }] });
	assert.deepEqual(store.getPlugin("a").capabilities, ["tabs:read", "schedule"]);
	assert.deepEqual(store.getPlugin("a").grantedCapabilities, ["schedule"]);
});

test("a rejected manifest keeps its reason and cannot be enabled by the list", async () => {
	const { store } = await setup();
	receive({ event: "pluginsChanged", plugins: [plugin("bad", { enabled: true, rejectionReason: "Unknown capability \"page:edit\"." })] });
	const row = store.getPlugin("bad");
	assert.equal(row.rejectionReason, "Unknown capability \"page:edit\".");
	assert.equal(row.enabled, false);
});
