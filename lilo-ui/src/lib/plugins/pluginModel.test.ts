import assert from "node:assert/strict";
import test from "node:test";
import {
	capabilityLabelKey,
	coercePluginRow,
	missingRequiredSettings,
	parseSettingInput,
	pluginStatus,
	settingValue,
	ungrantedCapabilities,
	type PluginRow,
} from "./pluginModel";

const row = (overrides: Partial<PluginRow> = {}): PluginRow =>
	coercePluginRow({ id: "com.example.checks", title: "Checks", version: "1.0.0", ...overrides })!;

test("a row with no id is dropped, and a missing title shows the id", () => {
	assert.equal(coercePluginRow({ title: "Nameless" }), null);
	assert.equal(row({ title: "" }).title, "com.example.checks");
});

test("a rejected manifest is never enabled, whatever the host says", () => {
	const rejected = row({ enabled: true, rejectionReason: "Unknown capability \"page:edit\"." });
	assert.equal(rejected.enabled, false);
	assert.equal(pluginStatus(rejected), "rejected");
});

test("status follows enabled and running", () => {
	assert.equal(pluginStatus(row()), "disabled");
	assert.equal(pluginStatus(row({ enabled: true })), "enabled");
	assert.equal(pluginStatus(row({ enabled: true, running: true })), "running");
});

test("only image data URLs are kept as an icon", () => {
	assert.equal(row({ icon: "data:image/png;base64,AAAA" }).icon, "data:image/png;base64,AAAA");
	assert.equal(row({ icon: "https://example.com/icon.png" }).icon, undefined);
	assert.equal(row({ icon: "javascript:alert(1)" }).icon, undefined);
});

test("settings of an unknown type or without a name are dropped", () => {
	const plugin = row({
		settings: [
			{ name: "interval", type: "dropdown", title: "Check every", options: ["15m", "1h"], default: "1h" },
			{ name: "color", type: "color" as never, title: "Color" },
			{ name: "", type: "text", title: "Nameless" },
		],
	});
	assert.deepEqual(plugin.settings.map((spec) => spec.name), ["interval"]);
});

test("a setting shows its value, else the manifest default, else the empty value of its type", () => {
	const plugin = row({
		settings: [
			{ name: "interval", type: "dropdown", title: "Check every", options: ["15m", "1h"], default: "1h" },
			{ name: "retries", type: "number", title: "Retries" },
			{ name: "notify", type: "toggle", title: "Notify" },
			{ name: "mode", type: "dropdown", title: "Mode", options: ["fast", "slow"] },
			{ name: "token", type: "password", title: "Token" },
		],
		settingValues: { retries: 3 },
	});
	const value = (name: string) => settingValue(plugin, plugin.settings.find((spec) => spec.name === name)!);
	assert.equal(value("retries"), 3);
	assert.equal(value("interval"), "1h");
	assert.equal(value("notify"), false);
	assert.equal(value("mode"), "fast");
	assert.equal(value("token"), "");
});

test("a number field commits a number, and nothing for text that is not one", () => {
	const spec = { name: "retries", type: "number", title: "Retries" } as const;
	assert.equal(parseSettingInput(spec, " 4 "), 4);
	assert.equal(parseSettingInput(spec, "0"), 0);
	assert.equal(parseSettingInput(spec, ""), null);
	assert.equal(parseSettingInput(spec, "many"), null);
	assert.equal(parseSettingInput({ name: "token", type: "text", title: "Token" }, " keep "), " keep ");
});

test("a required setting left empty is listed, a filled one or a switch is not", () => {
	const plugin = row({
		settings: [
			{ name: "token", type: "password", title: "Token", required: true },
			{ name: "host", type: "text", title: "Host", required: true },
			{ name: "agree", type: "toggle", title: "Agree", required: true },
			{ name: "note", type: "text", title: "Note" },
		],
		settingValues: { host: "example.com" },
	});
	assert.deepEqual(missingRequiredSettings(plugin).map((spec) => spec.name), ["token"]);
});

test("capabilities asked for and not granted are what enabling shows", () => {
	const plugin = row({ capabilities: ["tabs:read", "schedule", "page:act"], grantedCapabilities: ["schedule"] });
	assert.deepEqual(ungrantedCapabilities(plugin), ["tabs:read", "page:act"]);
	assert.deepEqual(ungrantedCapabilities(row({ capabilities: ["schedule"], grantedCapabilities: ["schedule"] })), []);
});

test("known capabilities have a catalog key, unknown ones show as written", () => {
	assert.equal(capabilityLabelKey("tabs:read"), "plugins.capabilities.tabsRead");
	assert.equal(capabilityLabelKey("tabs:delete"), undefined);
});
