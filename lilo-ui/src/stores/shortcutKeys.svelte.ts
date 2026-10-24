import { on } from "../lib/bridge";

// The keys the user's bindings give each native action, so a hint never names keys that do nothing.
let _keys = $state<Record<string, string>>({});

/** The keys of the native action `id` ("tab.new") as the menus spell them; undefined when unbound. */
export function shortcutKeys(id: string): string | undefined {
	return _keys[id];
}

export function initShortcutKeysStore(): void {
	on("shortcutKeys", (data) => {
		_keys = data.keys;
	});
}
