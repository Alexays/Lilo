import { on } from "../lib/bridge";
import { mediaActions } from "../lib/bridge/actions";
import type { BridgeCallTab, BridgeMediaTab } from "../lib/bridge/protocol";
import { getActiveTabId } from "./tabs.svelte";

let _tabs = $state.raw<BridgeMediaTab[]>([]);
let _calls = $state.raw<BridgeCallTab[]>([]);

export function initMediaStore(): void {
	on("mediaActivity", (data) => {
		_tabs = data.tabs;
		_calls = data.calls;
	});
	mediaActions.load();
}

// A call stays on its card even while shown: it is controlled from anywhere.
const _callTab = $derived(_calls[0]);

// The shown tab has its own controls: the card is for media playing elsewhere. The call's own
// sound belongs to its call card.
const _cardTab = $derived.by(() => {
	const others = _tabs.filter((tab) => tab.id !== getActiveTabId() && tab.id !== _callTab?.id);
	return others.find((tab) => tab.playing) ?? others[0];
});

/** The tab the sidebar's media card shows: one playing in the background first, else one paused from the card. */
export const getMediaCardTab = (): BridgeMediaTab | undefined => _cardTab;

/** The call the sidebar's call card shows, the same one ⇧⌘M toggles the microphone of. */
export const getCallCardTab = (): BridgeCallTab | undefined => _callTab;
