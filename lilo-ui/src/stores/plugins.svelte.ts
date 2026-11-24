// Plugin store: the plugins the host found, enabled or not, with the optimistic wait on their toggles.

import { on } from "../lib/bridge";
import { pluginActions } from "../lib/bridge/actions";
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

export function initPluginsStore(): void {
	on("pluginsChanged", (data) => {
		_plugins = (Array.isArray(data.plugins) ? data.plugins : []).map(coercePluginRow).filter((row) => row !== null);
		_loaded = true;
		for (const [id, { enabled }] of Object.entries(_pending)) {
			if (getPlugin(id)?.enabled !== !enabled) settle(id);
		}
	});
}

/** Asks the host for the list; the Plugins section calls it when it opens, so a closed Settings costs nothing. */
export const loadPlugins = (): void => pluginActions.load();

export const getPlugins = (): PluginRow[] => _plugins;
export const getPlugin = (id: string): PluginRow | undefined => _plugins.find((plugin) => plugin.id === id);
/** False until the host first answered: the section shows nothing rather than an empty state. */
export const arePluginsLoaded = (): boolean => _loaded;
export const isPluginPending = (id: string): boolean => id in _pending;

export function setPluginEnabled(id: string, enabled: boolean): void {
	if (isPluginPending(id) || getPlugin(id)?.enabled === enabled) return;
	_pending = { ..._pending, [id]: { enabled, timer: setTimeout(() => settle(id), PENDING_TIMEOUT_MS) } };
	pluginActions.setEnabled(id, enabled);
}

export function setPluginSetting(id: string, name: string, value: BridgePluginSettingValue): void {
	pluginActions.setSetting(id, name, value);
}

export const revokePluginCapability = (id: string, capability: string): void => pluginActions.revokeCapability(id, capability);
export const showPluginInFinder = (id: string): void => pluginActions.showInFinder(id);
export const stopPlugin = (id: string): void => pluginActions.stop(id);
