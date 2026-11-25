// Plugin store: the plugins the host found, enabled or not, with the optimistic wait on their toggles.
// The module is loaded with the Plugins section, not with the chrome: nothing here belongs in the first frame.

import { on, postMessage } from "../lib/bridge";
import type { BridgePluginSettingValue } from "../lib/bridge/protocol";
import { coercePluginRow, type PluginRow } from "../lib/plugins/pluginModel";

// Raw: every `pluginsChanged` (a plugin starting or stopping) replaces the list, so deep proxies would be rebuilt for nothing.
let _plugins = $state.raw<PluginRow[]>([]);
let _loaded = $state(false);

// An enable or disable is pending until the host's next `pluginsChanged` confirms it, so the switch never shows
// a state the host has not reached; if none arrives the wait ends, and the switch falls back to what the host last said.
const PENDING_TIMEOUT_MS = 8000;
let _pending = $state.raw<Record<string, { enabled: boolean; timer: ReturnType<typeof setTimeout> }>>({});

function settle(id: string): void {
	if (!(id in _pending)) return;
	clearTimeout(_pending[id].timer);
	const { [id]: _settled, ...rest } = _pending;
	_pending = rest;
}

// The listener registers when the module loads: the Plugins section loads it, and nothing else needs it.
on("pluginsChanged", (data) => {
	_plugins = (Array.isArray(data.plugins) ? data.plugins : []).map(coercePluginRow).filter((row) => row !== null);
	_loaded = true;
	for (const [id, { enabled }] of Object.entries(_pending)) {
		if (getPlugin(id)?.enabled !== !enabled) settle(id);
	}
});

/** Asks the host for the list; the Plugins section calls it when it opens, so a closed Settings costs nothing. */
export const loadPlugins = (): void => postMessage("getPlugins");

export const getPlugins = (): PluginRow[] => _plugins;
export const getPlugin = (id: string): PluginRow | undefined => _plugins.find((plugin) => plugin.id === id);
/** False until the host first answered: the section shows nothing rather than an empty state. */
export const arePluginsLoaded = (): boolean => _loaded;
export const isPluginPending = (id: string): boolean => id in _pending;

export function setPluginEnabled(id: string, enabled: boolean): void {
	if (isPluginPending(id) || getPlugin(id)?.enabled === enabled) return;
	_pending = { ..._pending, [id]: { enabled, timer: setTimeout(() => settle(id), PENDING_TIMEOUT_MS) } };
	postMessage("setPluginEnabled", { id, enabled });
}

export function setPluginSetting(id: string, name: string, value: BridgePluginSettingValue): void {
	postMessage("setPluginSetting", { id, name, value });
}

export const revokePluginCapability = (id: string, capability: string): void =>
	postMessage("revokePluginCapability", { id, capability });
export const showPluginInFinder = (id: string): void => postMessage("showPluginInFinder", { id });
export const stopPlugin = (id: string): void => postMessage("stopPlugin", { id });
