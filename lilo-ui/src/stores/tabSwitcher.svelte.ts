// The recent tabs switcher. Native owns the keys and sends the rows; the chrome owns the selection, so the pointer can move
// it too, and activates it when native reports the release.

import { on } from "../lib/bridge";
import { tabActions } from "../lib/bridge/actions";
import type { BridgeRecentTab } from "../lib/bridge/protocol";
import { t } from "../lib/i18n/state.svelte";

/** How long ago, in its largest whole unit: "just now", "5 min ago", "1 h ago", "2 d ago". */
export function formatAgo(elapsedMs: number): string {
	const minutes = Math.floor(elapsedMs / 60_000);
	if (minutes < 1) return t("tabSwitcher.justNow");
	if (minutes < 60) return t("tabSwitcher.minutesAgo", { count: minutes });
	if (minutes < 1440) return t("tabSwitcher.hoursAgo", { count: Math.floor(minutes / 60) });
	return t("tabSwitcher.daysAgo", { count: Math.floor(minutes / 1440) });
}

// The panel waits this long before showing, so a quick Control-Tab tap switches without flashing it.
export const TAB_SWITCHER_REVEAL_DELAY_MS = 150;

let _tabs = $state.raw<BridgeRecentTab[]>([]);
let _selected = $state(0);
let _visible = $state(false);
let _openedAt = 0;
let revealTimer: ReturnType<typeof setTimeout> | null = null;

export function getSwitcherTabs(): BridgeRecentTab[] {
	return _tabs;
}

export function getSwitcherSelection(): number {
	return _selected;
}

export function isTabSwitcherVisible(): boolean {
	return _visible;
}

/** When the switcher opened: the rows' ages count from it, so they hold still while it is open. */
export function getSwitcherOpenedAt(): number {
	return _openedAt;
}

export function selectSwitcherTab(index: number): void {
	_selected = index;
}

/** Closes the switcher, on the tab at `index` when there is one. */
export function closeTabSwitcher(index?: number): void {
	const tab = index === undefined ? undefined : _tabs[index];
	if (revealTimer !== null) clearTimeout(revealTimer);
	revealTimer = null;
	_tabs = [];
	_visible = false;
	if (tab) tabActions.switchToRecent(tab.id);
}

export function initTabSwitcherStore(): void {
	on("tabSwitcherOpened", ({ tabs, selected }) => {
		if (revealTimer !== null) clearTimeout(revealTimer);
		_tabs = tabs;
		_selected = selected;
		_openedAt = Date.now();
		_visible = false;
		revealTimer = setTimeout(() => {
			revealTimer = null;
			_visible = true;
		}, TAB_SWITCHER_REVEAL_DELAY_MS);
	});
	on("tabSwitcherMoved", ({ by }) => {
		if (_tabs.length === 0) return;
		_selected = (_selected + by + _tabs.length) % _tabs.length;
	});
	// A row clicked already closed it: the release that follows finds nothing to open.
	on("tabSwitcherClosed", ({ commit }) => {
		if (_tabs.length > 0) closeTabSwitcher(commit ? _selected : undefined);
	});
}
