import {
	on,
	type BridgeBrowserStateChangedPayload,
	type BridgeTabSnapshot,
} from "../lib/bridge";
import { tabActions } from "../lib/bridge/actions";
import { DEFAULT_TAB_TITLE } from "../lib/bridge/defaults";
import { t } from "../lib/i18n/state.svelte";
import { getActiveSpaceId } from "./spaces.svelte";
import { openCommandBar, closeCommandBar } from "./commandBar.svelte";
import { dragExcludedTabId } from "./folders.svelte";
import { getSpaceSidebar, initSidebarStore } from "./sidebar.svelte";

// Façade over the unified sidebar store (stores/sidebar.svelte.ts), which owns the state and
// the bridge listeners. This module keeps the public tab-getter surface, the drag-context
// read-time filtering, and the tab-related UI side effects.

export type TabState = BridgeTabSnapshot;

function resolveSpaceId(spaceId?: string): string {
	return spaceId || getActiveSpaceId() || "";
}

export function getTabs(spaceId?: string): TabState[] {
	const targetSpaceId = resolveSpaceId(spaceId);
	const tabs = getSpaceSidebar(targetSpaceId).tabs;
	const excludedTabId = dragExcludedTabId(targetSpaceId);
	return excludedTabId ? tabs.filter((tab) => tab.id !== excludedTabId) : tabs;
}

export function getOpenTabs(spaceId?: string): TabState[] {
	return getTabs(spaceId).filter((tab) => !tab.isClosed);
}

/**
 * Same tab set as getTabs (including the transient drag exclusion) as a Map. The common
 * no-drag path returns the view's precomputed Map so components don't rebuild one per patch.
 */
export function getTabsById(spaceId?: string): Map<string, TabState> {
	const targetSpaceId = resolveSpaceId(spaceId);
	const tabsById = getSpaceSidebar(targetSpaceId).view.tabsById;
	const excludedTabId = dragExcludedTabId(targetSpaceId);
	if (!excludedTabId || !tabsById.has(excludedTabId)) return tabsById;
	const filtered = new Map(tabsById);
	filtered.delete(excludedTabId);
	return filtered;
}

/** Precomputed per store write; the array identity only changes when a bookmark changes. */
export function getBookmarkedTabs(spaceId?: string): TabState[] {
	const targetSpaceId = resolveSpaceId(spaceId);
	const bookmarked = getSpaceSidebar(targetSpaceId).view.bookmarked;
	const excludedTabId = dragExcludedTabId(targetSpaceId);
	if (!excludedTabId || !bookmarked.some((tab) => tab.id === excludedTabId)) return bookmarked;
	return bookmarked.filter((tab) => tab.id !== excludedTabId);
}

export function getActiveTabId(spaceId?: string): string {
	return getActiveTab(spaceId)?.id ?? "";
}

/** A new tab still waiting for a page. A terminal has no URL either, but is never blank. */
export function isBlankTab(tab: TabState | undefined): tab is TabState {
	return tab != null && !tab.url && tab.kind !== "terminal";
}

/** A tab title as shown: native's blank-tab placeholder (`Tab.placeholderTitle`) reads in the app's language. */
export function tabDisplayTitle(title: string): string {
	return title === DEFAULT_TAB_TITLE ? t("tabItem.newTab") : title;
}

/** Map lookup, not a scan: this runs in several always-mounted components per tab patch. */
export function getActiveTab(spaceId?: string): TabState | undefined {
	const state = getSpaceSidebar(resolveSpaceId(spaceId));
	const tab = state.view.tabsById.get(state.activeTabId);
	return tab && !tab.isClosed ? tab : undefined;
}

export function isSpaceHydrated(spaceId?: string): boolean {
	return getSpaceSidebar(resolveSpaceId(spaceId)).hydrated;
}

export function initTabStore(): void {
	initSidebarStore();

	// Registered after the sidebar store's listener, so the state is applied, and before the spaces store's, which
	// still holds the previous active space id.
	on("browserStateChanged", handleStateChangedSideEffects);

	on("toggleNewTab", () => {
		const active = getActiveTab();
		if (isBlankTab(active)) {
			tabActions.close(active.id);
			closeCommandBar();
		} else {
			openCommandBar("", true);
		}
	});
}

function handleStateChangedSideEffects(
	data: BridgeBrowserStateChangedPayload,
): void {
	const previousActiveSpaceId = getActiveSpaceId();
	if (!data.changedSpaceId || data.changedSpaceId === previousActiveSpaceId) {
		return;
	}

	if (isBlankTab(getActiveTab(data.changedSpaceId))) {
		openCommandBar("", true);
	}
}
