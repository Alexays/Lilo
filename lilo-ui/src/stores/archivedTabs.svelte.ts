// The window's Space's archived tabs, newest first: native sends them on every archive change and Space switch.

import { on } from "../lib/bridge";
import { tabActions } from "../lib/bridge/actions";
import type { BridgeArchivedTab } from "../lib/bridge/protocol";

/** How long an archived tab stays one click away in the tab list; older ones are left to the command bar. */
export const RECENT_ARCHIVE_MS = 24 * 60 * 60 * 1000;

let _tabs = $state.raw<BridgeArchivedTab[]>([]);

export function initArchivedTabsStore(): void {
	on("archivedTabs", (data) => {
		_tabs = data.tabs;
	});
	tabActions.loadArchived();
}

export function getRecentArchivedTabs(now = Date.now()): BridgeArchivedTab[] {
	return _tabs.filter((tab) => now - tab.archivedAt < RECENT_ARCHIVE_MS);
}
