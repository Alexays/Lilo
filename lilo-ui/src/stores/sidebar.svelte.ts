import {
	on,
	postMessage,
	type BridgeBrowserStatePatchPayload,
	type BridgeBrowserStateChangedPayload,
	type BridgeInitialStatePayload,
	type BridgeTabUpdatedPayload,
} from "../lib/bridge";
import type {
	BridgeSidebarChangedPayload,
	BridgeSidebarTreeItemSnapshot,
	BridgeSpaceBrowserStatePayload,
	BridgeTabFolderSnapshot,
	BridgeTabSnapshot,
} from "../lib/bridge/protocol";
import { coerceTabFolderSnapshot } from "../lib/bridge/coerce";
import { coerceTabPatch, coerceTabSnapshot } from "../lib/bridge/tabProtocol.gen";
import {
	findOpenTabById,
	normalizeSpaceTabsState,
	removeTabsFromState,
	resolveActiveTabId,
} from "./tabState";
import {
	computeSidebarView,
	viewWithUpdatedTabs,
	type SidebarView,
} from "./sidebarView";

// Tabs, folders and treeItems of a space live in one record written by one set of bridge listeners, so they never
// disagree; `tabs.svelte.ts` and `folders.svelte.ts` are facades over it.

interface SpaceSidebarState {
	tabs: BridgeTabSnapshot[];
	activeTabId: string;
	hydrated: boolean;
	folders: BridgeTabFolderSnapshot[];
	treeItems: BridgeSidebarTreeItemSnapshot[];
	view: SidebarView;
}

const EMPTY_SPACE_STATE: SpaceSidebarState = {
	tabs: [],
	activeTabId: "",
	hydrated: false,
	folders: [],
	treeItems: [],
	view: computeSidebarView([], [], []),
};

// Raw on purpose: a deep `$state` would proxy every tab snapshot and allocate a signal per property read, for a
// per-space invalidation the render path does not need (untouched spaces keep their array/Map identities).
let _bySpace = $state.raw<Record<string, SpaceSidebarState>>({});

export function getSpaceSidebar(spaceId?: string): SpaceSidebarState {
	return spaceId ? (_bySpace[spaceId] ?? EMPTY_SPACE_STATE) : EMPTY_SPACE_STATE;
}

export function getSidebarsBySpace(): Readonly<Record<string, SpaceSidebarState>> {
	return _bySpace;
}

function putSpaceSidebar(spaceId: string, state: SpaceSidebarState): void {
	_bySpace = { ..._bySpace, [spaceId]: state };
}

// --- post-apply notification ---

export interface SidebarAppliedEvent {
	spaceId: string;
	activeTabId: string;
	activeTab?: BridgeTabSnapshot;
	closedTabIds: string[];
	isFullReplace: boolean;
}

type SidebarAppliedListener = (event: SidebarAppliedEvent) => void;
const appliedListeners = new Set<SidebarAppliedListener>();

export function onSidebarApplied(listener: SidebarAppliedListener): () => void {
	appliedListeners.add(listener);
	return () => appliedListeners.delete(listener);
}

function notifyApplied(
	spaceId: string,
	options: { closedTabIds?: string[]; isFullReplace?: boolean } = {},
): void {
	if (!spaceId || appliedListeners.size === 0) return;
	const state = getSpaceSidebar(spaceId);
	const event: SidebarAppliedEvent = {
		spaceId,
		activeTabId: state.activeTabId,
		activeTab: findOpenTabById(state.tabs, state.activeTabId),
		closedTabIds: options.closedTabIds ?? [],
		isFullReplace: options.isFullReplace ?? false,
	};
	for (const listener of appliedListeners) listener(event);
}

// --- writers ---

const sameViewFlags = (a: BridgeTabSnapshot, b: BridgeTabSnapshot): boolean =>
	a.isPinned === b.isPinned &&
	a.isBookmarked === b.isBookmarked &&
	a.isClosed === b.isClosed;

const sameSnapshot = (a: BridgeTabSnapshot, b: BridgeTabSnapshot): boolean => {
	const keys = Object.keys(b) as (keyof BridgeTabSnapshot)[];
	return (
		keys.length === Object.keys(a).length &&
		keys.every((key) => Object.is(a[key], b[key]))
	);
};

function writeSpace(
	spaceId: string,
	next: Omit<SpaceSidebarState, "view">,
	options: { reuseView?: SidebarView } = {},
): void {
	const normalized = normalizeSpaceTabsState(next);
	const view =
		options.reuseView ??
		computeSidebarView(normalized.tabs, next.folders, next.treeItems);
	putSpaceSidebar(spaceId, { ...next, activeTabId: normalized.activeTabId, view });
}

// sidebarChanged patches the host sent before a click reached it still name the old tab: the
// click's target holds until a patch confirms it or this passes, then the host's latest wins.
const OPTIMISTIC_ACTIVATION_HOLD_MS = 500;

let heldActivation: {
	spaceId: string;
	tabId: string;
	hostActiveTabId: string | null;
	timer: ReturnType<typeof setTimeout>;
} | null = null;

function releaseHeldActivation(): void {
	const held = heldActivation;
	heldActivation = null;
	if (!held || held.hostActiveTabId === null) return;
	const current = getSpaceSidebar(held.spaceId);
	const activeTabId = resolveActiveTabId(current.tabs, held.hostActiveTabId);
	if (activeTabId === current.activeTabId) return;
	writeSpace(held.spaceId, { ...current, activeTabId }, { reuseView: current.view });
	notifyApplied(held.spaceId);
}

// Moves the highlight to an open `tabId` in the click's frame, ahead of the host's patch; it
// notifies like a real activation so commandBar/FindBar dismiss the same way.
export function optimisticallyActivateTab(tabId: string): void {
	for (const [spaceId, current] of Object.entries(_bySpace)) {
		const tab = findOpenTabById(current.tabs, tabId);
		if (!tab) continue;
		if (current.activeTabId === tabId) return;
		writeSpace(
			spaceId,
			{ ...current, activeTabId: tabId },
			{ reuseView: current.view },
		);
		if (heldActivation) clearTimeout(heldActivation.timer);
		heldActivation = {
			spaceId,
			tabId,
			hostActiveTabId: null,
			timer: setTimeout(releaseHeldActivation, OPTIMISTIC_ACTIVATION_HOLD_MS),
		};
		notifyApplied(spaceId);
		return;
	}
}

// The tab the host names active, unless a click's activation still holds: the host's pick is kept
// for its release, and a confirmation (or the held tab going) ends the hold.
function holdActivation(spaceId: string, tabs: BridgeTabSnapshot[], hostActiveTabId: string): string {
	const held = heldActivation?.spaceId === spaceId ? heldActivation : null;
	if (!held) return hostActiveTabId;
	if (hostActiveTabId === held.tabId || !findOpenTabById(tabs, held.tabId)) {
		clearTimeout(held.timer);
		heldActivation = null;
		return hostActiveTabId;
	}
	held.hostActiveTabId = hostActiveTabId;
	return held.tabId;
}

function ensureSpaceSidebar(spaceId?: string): void {
	if (spaceId && !_bySpace[spaceId]) {
		putSpaceSidebar(spaceId, EMPTY_SPACE_STATE);
	}
}

function deleteSpaceSidebar(spaceId: string): void {
	if (!_bySpace[spaceId]) return;
	pendingHydrationSpaces.delete(spaceId);
	const next = { ..._bySpace };
	delete next[spaceId];
	_bySpace = next;
}

// --- initial-state appliers (split mirrors init.ts's applier ordering: tabs first, folders second) ---

type TabInitialStatePayload = Pick<
	BridgeInitialStatePayload,
	"activeSpaceId" | "activeTabId" | "spaces" | "tabs"
>;

export function applySidebarTabInitialState(data: TabInitialStatePayload): void {
	const activeSpaceId = data.activeSpaceId || "";
	const next = Object.fromEntries(
		(data.spaces || []).flatMap((space) =>
			space.id ? [[space.id, EMPTY_SPACE_STATE]] : [],
		),
	) as Record<string, SpaceSidebarState>;

	if (activeSpaceId) {
		const tabs = data.tabs.map(coerceTabSnapshot);
		next[activeSpaceId] = {
			tabs,
			activeTabId: resolveActiveTabId(tabs, data.activeTabId || ""),
			hydrated: true,
			folders: [],
			treeItems: [],
			view: computeSidebarView(tabs, [], []),
		};
	}

	_bySpace = next;
}

export function applySidebarFolderInitialState(
	data: BridgeInitialStatePayload,
): void {
	const activeSpaceId = data.activeSpaceId || "";
	const next = { ..._bySpace };
	for (const space of data.spaces || []) {
		if (!space.id) continue;
		const current = next[space.id] ?? EMPTY_SPACE_STATE;
		const folders =
			space.id === activeSpaceId
				? (data.folders || []).map(coerceTabFolderSnapshot)
				: [];
		const treeItems = space.id === activeSpaceId ? data.treeItems || [] : [];
		next[space.id] = {
			...current,
			folders,
			treeItems,
			view: computeSidebarView(current.tabs, folders, treeItems),
		};
	}
	_bySpace = next;
}

// --- state-seq gap detection and resync ---

// `null` until a stamped message arrives. `resyncPending` and RESYNC_THROTTLE_MS keep a burst of out-of-order
// patches after one lost message to a single requestBrowserStateSync.
const RESYNC_THROTTLE_MS = 250;
let lastStateSeq: number | null = null;
let resyncPending = false;
let lastResyncRequestAt = 0;

/** Latches `resyncPending` so a burst posts once; a call after RESYNC_THROTTLE_MS re-posts, self-healing when the
 *  full-state response itself was lost.
 */
function requestResync(): void {
	const t = Date.now();
	if (resyncPending && t - lastResyncRequestAt < RESYNC_THROTTLE_MS) return;
	resyncPending = true;
	lastResyncRequestAt = t;
	postMessage("requestBrowserStateSync", {});
}

// Per-space hydration-pending set: decoupled from the global gap-recovery latch so that a
// non-hydrated-space resync does not discard valid contiguous patches for other (hydrated) spaces.
const pendingHydrationSpaces = new Set<string>();

// --- bridge event application ---

function applyBrowserStateChanged(data: BridgeBrowserStateChangedPayload): void {
	// Full state is always authoritative: accept regardless of seq, then reset tracking so
	// the next contiguous patch after this full state applies normally.
	lastStateSeq = data.stateSeq ?? null;
	resyncPending = false;
	lastResyncRequestAt = 0;
	const states = (data.states || []).filter((state) => state.spaceId);
	// Full states omit faviconDataURL for spaces already shipped, so capture previous favicons before applying any:
	// a cross-space move ships source and target, and applying the source first would drop the moved tab's favicon.
	const priorFaviconById = new Map<string, string>();
	// Only spaces named in the payload can lose tabs to it (cross-space moves ship source and
	// target together), so the pre-capture scan skips every other space's tab list.
	const payloadSpaceIds = new Set(states.map((state) => state.spaceId));
	for (const [spaceId, current] of Object.entries(_bySpace)) {
		if (!payloadSpaceIds.has(spaceId)) continue;
		for (const tab of current.tabs) {
			if (tab.faviconDataURL) priorFaviconById.set(tab.id, tab.faviconDataURL);
		}
	}
	for (const state of states) {
		replaceSpaceFromFullState(state, priorFaviconById);
	}
	if (data.changedSpaceId) {
		notifyApplied(data.changedSpaceId, { isFullReplace: true });
	}
}

function replaceSpaceFromFullState(
	state: BridgeSpaceBrowserStatePayload,
	priorFaviconById: ReadonlyMap<string, string>,
): void {
	const spaceId = state.spaceId;
	pendingHydrationSpaces.delete(spaceId);
	const previousById = _bySpace[spaceId]?.view.tabsById;
	const tabs = state.tabs.map((raw) => {
		const tab = coerceTabSnapshot(raw);
		// Recover favicons the payload omitted; tabs it DOES carry a favicon for keep the fresh value.
		tab.faviconDataURL ||= priorFaviconById.get(tab.id);
		// A space switch resends every tab: keeping the unchanged ones' identity spares their rows.
		const previous = previousById?.get(tab.id);
		return previous && sameSnapshot(previous, tab) ? previous : tab;
	});
	const tabIds = new Set(tabs.map((tab) => tab.id));

	// Tabs adopted by this space leave their previous space (cross-space moves). Only spaces
	// that actually lose a tab are rewritten, so unrelated spaces' readers stay untouched.
	for (const [currentSpaceId, current] of Object.entries(_bySpace)) {
		if (currentSpaceId === spaceId) continue;
		const removed = removeTabsFromState(current, tabIds);
		if (removed === current) continue;
		putSpaceSidebar(currentSpaceId, {
			...current,
			tabs: removed.tabs,
			activeTabId: removed.activeTabId,
			view: computeSidebarView(
				removed.tabs,
				current.folders,
				current.treeItems,
			),
		});
	}

	const existing = _bySpace[spaceId];
	const folders = (state.folders || []).map(coerceTabFolderSnapshot);
	const treeItems = state.treeItems || [];
	putSpaceSidebar(spaceId, {
		tabs,
		activeTabId: holdActivation(
			spaceId,
			tabs,
			resolveActiveTabId(tabs, state.activeTabId || "", existing?.activeTabId),
		),
		hydrated: true,
		folders,
		treeItems,
		view: computeSidebarView(tabs, folders, treeItems),
	});
}

function applyBrowserStatePatch(data: BridgeBrowserStatePatchPayload): void {
	const { stateSeq } = data;

	// A seq that is not the immediate successor means a lost delivery: discard the patch and request a resync.
	if (stateSeq !== undefined) {
		if (resyncPending || (lastStateSeq !== null && stateSeq !== lastStateSeq + 1)) {
			requestResync();
			return;
		}
		lastStateSeq = stateSeq;
	}

	const pending: PendingTabUpdates = new Map();
	for (const operation of data.operations || []) {
		switch (operation.kind) {
			case "tabUpdated":
				applyTabUpdated(operation, pending);
				break;
			case "sidebarChanged":
				flushTabUpdates(pending);
				applySidebarChanged(operation);
				break;
		}
	}
	flushTabUpdates(pending);
}

function applyUpserts<T extends { id: string }>(
	existing: T[],
	removedIds: Set<string>,
	upsertsById: Map<string, T>,
	key: (item: T) => string = (item) => item.id,
): T[] {
	if (removedIds.size === 0 && upsertsById.size === 0) return existing;
	const existingIds = new Set(existing.map(key));
	const next = existing
		.filter((item) => !removedIds.has(key(item)))
		.map((item) => upsertsById.get(key(item)) ?? item);
	for (const [id, item] of upsertsById) {
		if (!existingIds.has(id)) next.push(item);
	}
	return next;
}

function applySidebarChanged(data: BridgeSidebarChangedPayload): void {
	const spaceId = data.spaceId || "";
	if (!spaceId) return;
	const current = getSpaceSidebar(spaceId);
	// A diff against a non-hydrated space omits tabs missing here: resync this space only, so other spaces'
	// contiguous patches still apply and the global gap-recovery latch stays untouched.
	if (!current.hydrated) {
		if (!pendingHydrationSpaces.has(spaceId)) {
			pendingHydrationSpaces.add(spaceId);
			postMessage("requestBrowserStateSync", { spaceId });
		}
		return;
	}

	const removedTabIds = new Set(data.removedTabIds ?? []);
	// An upsert whose favicon is unchanged leaves faviconDataURL out: keep the one already held.
	const upsertTabsById = new Map(
		(data.upsertTabs ?? []).map((raw) => {
			const tab = coerceTabSnapshot(raw);
			if (raw.faviconDataURL === undefined) {
				tab.faviconDataURL = current.view.tabsById.get(raw.id)?.faviconDataURL;
			}
			return [tab.id, tab];
		}),
	);
	const nextTabs = applyUpserts(current.tabs, removedTabIds, upsertTabsById);

	const removedFolderIds = new Set(data.removedFolderIds ?? []);
	const upsertFoldersById = new Map(
		(data.upsertFolders ?? []).map((folder) => [
			folder.id,
			coerceTabFolderSnapshot(folder),
		]),
	);
	const nextFolders = applyUpserts(current.folders, removedFolderIds, upsertFoldersById);

	// Tree deltas key on itemId: the host synthesizes each item's `id` afresh.
	const removedTreeItemIds = new Set(data.removedTreeItemIds ?? []);
	const upsertTreeItemsById = new Map((data.upsertTreeItems ?? []).map((item) => [item.itemId, item]));
	const nextTreeItems =
		data.treeItems ?? applyUpserts(current.treeItems, removedTreeItemIds, upsertTreeItemsById, (item) => item.itemId);

	// "Closed" for listeners = pruned from the space, or surviving (pinned/bookmarked) but
	// flipped to isClosed by this very patch.
	const closedTabIds = [...removedTabIds];
	for (const [id, tab] of upsertTabsById) {
		const previous = current.view.tabsById.get(id);
		if (tab.isClosed && previous && !previous.isClosed) closedTabIds.push(id);
	}

	// When the patch carries only an activeTabId change (no structural mutations), reuse the
	// precomputed view: SidebarView does not embed activeTabId, so it is still correct.
	const isActivationOnly =
		upsertTabsById.size === 0 &&
		removedTabIds.size === 0 &&
		upsertFoldersById.size === 0 &&
		removedFolderIds.size === 0 &&
		nextTreeItems === current.treeItems;
	const activeTabId = holdActivation(spaceId, nextTabs, resolveActiveTabId(nextTabs, data.activeTabId || ""));

	// The host's confirmation of a click the optimistic activation already applied: nothing
	// changes, so the record keeps its identity and no reader re-runs.
	if (!isActivationOnly || activeTabId !== current.activeTabId) {
		writeSpace(
			spaceId,
			{
				...current,
				tabs: nextTabs,
				folders: nextFolders,
				treeItems: nextTreeItems,
				activeTabId,
			},
			isActivationOnly ? { reuseView: current.view } : {},
		);
	}
	notifyApplied(spaceId, { closedTabIds });
}

// Consecutive tabUpdated operations of one patch accumulate per space and land in one write.
type PendingTabUpdates = Map<
	string,
	{ tabs: BridgeTabSnapshot[]; updated: Map<string, BridgeTabSnapshot>; structural: boolean }
>;

function flushTabUpdates(pending: PendingTabUpdates): void {
	for (const [spaceId, { tabs, updated, structural }] of pending) {
		const current = getSpaceSidebar(spaceId);
		writeSpace(
			spaceId,
			{ ...current, tabs },
			structural ? {} : { reuseView: viewWithUpdatedTabs(current.view, updated) },
		);
	}
	pending.clear();
}

function applyTabUpdated(data: BridgeTabUpdatedPayload, pending: PendingTabUpdates): void {
	const spaceId = data.spaceId || "";
	const patch = data.tab;
	if (!spaceId || !patch?.id) return;

	// Runtime patches omit the favicon (and any unchanged field), so merge the present fields
	// onto the existing tab instead of wholesale-replacing it.
	const entry = pending.get(spaceId);
	const tabs = entry?.tabs ?? getSpaceSidebar(spaceId).tabs;
	const index = tabs.findIndex((t) => t.id === patch.id);
	if (index < 0) return;

	// A patch that changes nothing must not rewrite the record: every sidebar reader re-runs on
	// each write.
	const previous = tabs[index];
	const fields = coerceTabPatch(patch);
	const keys = Object.keys(fields) as (keyof BridgeTabSnapshot)[];
	if (keys.every((key) => Object.is(fields[key], previous[key]))) return;

	// The patch's activeTabId is ignored: it is the host's as of when the patch was buffered, so it
	// can predate a click's optimistic activation and bounce the highlight back. Activation arrives
	// through sidebarChanged and full state only.
	const tab = { ...previous, ...fields };
	const structural = !sameViewFlags(previous, tab);
	if (entry) {
		entry.tabs[index] = tab;
		entry.updated.set(tab.id, tab);
		entry.structural ||= structural;
		return;
	}
	const nextTabs = tabs.slice();
	nextTabs[index] = tab;
	pending.set(spaceId, { tabs: nextTabs, updated: new Map([[tab.id, tab]]), structural });
}

// --- init ---

let initialized = false;

export function initSidebarStore(): void {
	if (initialized) return;
	initialized = true;

	on("spaceCreated", ({ id }) => ensureSpaceSidebar(id));
	on("spaceDeleted", ({ id }) => {
		if (id) deleteSpaceSidebar(id);
	});
	on("browserStateChanged", applyBrowserStateChanged);
	on("browserStatePatch", applyBrowserStatePatch);
}
