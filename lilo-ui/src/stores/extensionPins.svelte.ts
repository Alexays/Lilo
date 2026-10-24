// Extensions pinned to the address bar. Persisted through the host's generic settings
// key-value store, so the list survives a relaunch without a dedicated bridge command.

import { on } from "../lib/bridge";
import { settingsActions } from "../lib/bridge/actions";
import { getExtensions } from "./extensions.svelte";

const SETTING_KEY = "pinnedExtensions";

let _pinned = $state.raw<string[]>([]);

export function initExtensionPinsStore(): void {
	on("settingsLoaded", (data) => {
		_pinned = parsePinned(data.settings?.[SETTING_KEY]);
	});
	// The native context menu of an address-bar or menu-listed extension.
	on("extensionMenuAction", (data) => {
		if (data.action === "togglePin") toggleExtensionPin(data.id);
	});
}

function parsePinned(raw: string | undefined): string[] {
	if (!raw) return [];
	return raw
		.split(",")
		.map((id) => id.trim())
		.filter(Boolean);
}

// Ids of uninstalled extensions stay in the setting until the next write but never show.
const _pinnedIds = $derived(_pinned.filter((id) => getExtensions().some((ext) => ext.id === id)));

export function getPinnedExtensionIds(): string[] {
	return _pinnedIds;
}

export function isExtensionPinned(id: string): boolean {
	return getPinnedExtensionIds().includes(id);
}

function savePinned(pinned: string[]): void {
	_pinned = pinned;
	// Applied locally first: the host echoes settingsLoaded back on the same value.
	settingsActions.set(SETTING_KEY, pinned.join(","));
}

/** Pins `id` after the existing pins; a no-op when it is already pinned. */
export function pinExtension(id: string): void {
	const pinned = getPinnedExtensionIds();
	if (!pinned.includes(id)) savePinned([...pinned, id]);
}

export function toggleExtensionPin(id: string): void {
	const pinned = getPinnedExtensionIds();
	if (pinned.includes(id)) savePinned(pinned.filter((pinnedId) => pinnedId !== id));
	else pinExtension(id);
}
