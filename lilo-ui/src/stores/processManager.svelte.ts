import { on } from "../lib/bridge";
import { processManagerActions } from "../lib/bridge/actions";
import type { BridgeProcessManagerActionStatusPayload, BridgeProcessSnapshot, BridgeTabSnapshot } from "../lib/bridge/protocol";
import { processOverview } from "../components/diagnostics/processManagerModel";
import { getSidebarsBySpace } from "./sidebar.svelte";

// The Process Manager's snapshot and search, shared by its navigation and its page.
let _snapshot = $state.raw<BridgeProcessSnapshot | null>(null);
let _status = $state<BridgeProcessManagerActionStatusPayload | null>(null);
let _query = $state("");
let _listening = false;

const _overview = $derived(processOverview(_snapshot));

// Favicons and sleeping tabs come from the sidebar, which knows every open tab.
const _sidebarTabs = $derived.by(() => {
	// eslint-disable-next-line svelte/prefer-svelte-reactivity -- rebuilt whole by the $derived, never mutated after
	const byId = new Map<string, { tab: BridgeTabSnapshot; spaceId: string }>();
	for (const [spaceId, state] of Object.entries(getSidebarsBySpace())) {
		for (const tab of state.tabs) {
			if (!tab.isClosed && tab.kind !== "terminal") byId.set(tab.id, { tab, spaceId });
		}
	}
	return byId;
});

const _sleepingTabs = $derived.by(() => {
	if (!_snapshot) return [];
	const live = new Set(_overview.tabs.map((usage) => usage.tab.id));
	return [..._sidebarTabs.values()].filter(({ tab }) => !live.has(tab.id));
});

export const getProcessSnapshot = (): BridgeProcessSnapshot | null => _snapshot;
export const getProcessOverview = (): ReturnType<typeof processOverview> => _overview;
export const getProcessSidebarTab = (id: string): BridgeTabSnapshot | undefined => _sidebarTabs.get(id)?.tab;
/** Open tabs with no live process, in sidebar order. */
export const getSleepingTabs = (): { tab: BridgeTabSnapshot; spaceId: string }[] => _sleepingTabs;
export const getProcessQuery = (): string => _query;
export const getProcessStatus = (): BridgeProcessManagerActionStatusPayload | null => _status;

export function setProcessQuery(query: string): void {
	_query = query;
}

export function setProcessStatus(status: BridgeProcessManagerActionStatusPayload | null): void {
	_status = status;
}

/** Asks for a snapshot; listens from the first open on. */
export function loadProcessSnapshot(): void {
	if (!_listening) {
		_listening = true;
		on("processSnapshotUpdated", (data) => {
			_snapshot = data;
		});
		on("processManagerActionCompleted", (data) => {
			_status = data;
		});
	}
	processManagerActions.load();
}
