// Made-up plugins covering what the panel renders: each state of a row and each kind of declared setting.
import type { BridgePluginRow } from "../src/lib/bridge/protocol";

const dir = (id: string) => `/Users/example/Library/Application Support/Lilo/Plugins/${id}`;

export function pluginFixtures(): BridgePluginRow[] {
	return [
		// Enabled and running, everything it asked for granted.
		{
			id: "com.example.automations",
			title: "Automations",
			version: "1.2.0",
			enabled: true,
			running: true,
			capabilities: ["schedule", "tabs:read", "settings:store"],
			grantedCapabilities: ["schedule", "tabs:read", "settings:store"],
			settings: [
				{ name: "interval", type: "dropdown", title: "Check every", options: ["15m", "1h", "1d"], default: "1h" },
				{ name: "token", type: "password", title: "API token", required: true },
			],
			settingValues: { token: "example-token" },
			supportDir: dir("com.example.automations"),
		},
		// Enabled but idle: the sidecar exited and starts again on demand.
		{
			id: "com.example.connectors",
			title: "Connectors",
			version: "0.9.0",
			enabled: true,
			running: false,
			capabilities: ["tabs:open"],
			grantedCapabilities: ["tabs:open"],
			settings: [],
			settingValues: {},
			supportDir: dir("com.example.connectors"),
		},
		// Disabled, nothing granted yet, one setting of each type.
		{
			id: "com.example.reading-list",
			title: "Reading List",
			version: "2.0.1",
			enabled: false,
			running: false,
			capabilities: ["page:read", "page:act", "files:plugin-dir"],
			grantedCapabilities: [],
			settings: [
				{ name: "folder", type: "text", title: "Folder name", default: "Reading" },
				{ name: "key", type: "password", title: "Sync key" },
				{ name: "order", type: "dropdown", title: "Order", options: ["Newest first", "Oldest first"] },
				{ name: "notify", type: "toggle", title: "Notify when saved", default: true },
				{ name: "limit", type: "number", title: "Keep at most", default: 50 },
				{ name: "account", type: "text", title: "Account", required: true },
			],
			settingValues: {},
			supportDir: dir("com.example.reading-list"),
		},
		// Failed validation: listed with its reason, never started.
		{
			id: "com.example.broken",
			title: "Broken Notes",
			version: "0.1.0",
			enabled: false,
			running: false,
			rejectionReason: "Unknown capability \"page:edit\" in capabilities.",
			capabilities: [],
			grantedCapabilities: [],
			settings: [],
			settingValues: {},
			supportDir: dir("com.example.broken"),
		},
	];
}
