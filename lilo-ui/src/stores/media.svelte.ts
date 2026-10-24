import { on } from "../lib/bridge";
import { mediaActions } from "../lib/bridge/actions";
import type { BridgeMediaTab } from "../lib/bridge/protocol";
import { getActiveTabId } from "./tabs.svelte";

let _tabs = $state.raw<BridgeMediaTab[]>([]);

export function initMediaStore(): void {
	on("mediaActivity", (data) => {
		_tabs = data.tabs;
	});
	mediaActions.load();
}

// The shown tab has its own controls: the card is for media playing elsewhere.
const _cardTab = $derived.by(() => {
	const others = _tabs.filter((tab) => tab.id !== getActiveTabId());
	return others.find((tab) => tab.playing) ?? others[0];
});

/** The tab the sidebar's media card shows: one playing in the background first, else one paused from the card. */
export const getMediaCardTab = (): BridgeMediaTab | undefined => _cardTab;
