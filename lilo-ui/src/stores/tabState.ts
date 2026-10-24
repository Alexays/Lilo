export interface TabStateLike {
	id: string;
	isClosed: boolean;
}

interface SpaceTabsStateLike<T extends TabStateLike> {
	tabs: T[];
	activeTabId: string;
	hydrated: boolean;
}

export function findOpenTabById<T extends TabStateLike>(
	tabs: T[],
	tabId: string,
): T | undefined {
	if (!tabId) {
		return undefined;
	}

	return tabs.find((tab) => tab.id === tabId && !tab.isClosed);
}

export function resolveActiveTabId<T extends TabStateLike>(
	tabs: T[],
	preferredActiveTabId = "",
	fallbackActiveTabId = "",
): string {
	return (
		findOpenTabById(tabs, preferredActiveTabId)?.id ??
		findOpenTabById(tabs, fallbackActiveTabId)?.id ??
		""
	);
}

export function normalizeSpaceTabsState<T extends TabStateLike>(
	state: SpaceTabsStateLike<T>,
): SpaceTabsStateLike<T> {
	const activeTabId = resolveActiveTabId(state.tabs, state.activeTabId);
	return activeTabId === state.activeTabId ? state : { ...state, activeTabId };
}

export function removeTabsFromState<T extends TabStateLike>(
	state: SpaceTabsStateLike<T>,
	tabIds: Set<string>,
): SpaceTabsStateLike<T> {
	if (
		!tabIds.has(state.activeTabId) &&
		!state.tabs.some((tab) => tabIds.has(tab.id))
	) {
		return state;
	}

	return normalizeSpaceTabsState({
		...state,
		tabs: state.tabs.filter((tab) => !tabIds.has(tab.id)),
		activeTabId: tabIds.has(state.activeTabId) ? "" : state.activeTabId,
	});
}
