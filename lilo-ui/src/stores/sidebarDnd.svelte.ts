import { dndEngineStore, type DndActiveDrag } from "../lib/dndEngine/store.svelte";
import {
	commitFromDndProjection,
	materializeSidebarProjection,
	projectSidebarItemsWithShadow,
	projectZoneItems,
	type SidebarDndItem,
	type SidebarDragSnapshot,
	type SidebarPlaceholder,
	type SidebarZoneRef,
} from "../lib/dndEngine/adapters/sidebar";
import { folderDropIndex } from "../lib/sidebarDnd/folderTargeting";
import { folderActions } from "../lib/bridge/actions";
import type {
	BridgeSidebarDropPayload,
	BridgeSidebarItemKind,
} from "../lib/bridge/protocol";

const DROP_SETTLE_MS = 180;
const RECENT_DROP_MS = 250;
// A collapsed folder held under the drag this long opens, so the drop can aim inside it.
const AUTO_EXPAND_MS = 600;

// Mirrors the engine's drag into reactive state. The engine stays rune-free (its
// unit tests import it directly under tsx), so the bridge is this one counter that
// the engine bumps whenever the drag outcome changes.
let dragVersion = $state(0);
let hadActiveDrag = false;
let publishedDragActive = false;
// The last placeholder shown, kept in place while a collapsed folder is the target.
let heldPlaceholder: SidebarPlaceholder | null = null;
dndEngineStore.subscribe(() => {
	dragVersion += 1;
	const isActive = dndEngineStore.activeDrag !== null;
	// A fresh gesture drops whatever hold the previous drop left behind.
	if (isActive && !hadActiveDrag) {
		resetSidebarDrag();
		heldPlaceholder = null;
	}
	hadActiveDrag = isActive;
	const snapshot = snapshotFrom(dndEngineStore.activeDrag);
	heldPlaceholder = snapshot?.placeholder ?? null;
	scheduleAutoExpand(snapshot?.intoCollapsedFolder ? snapshot.target?.parentFolderId ?? null : null);
	publishDragActive();
});

let autoExpandFolderId: string | null = null;
let autoExpandTimer: ReturnType<typeof setTimeout> | null = null;

function scheduleAutoExpand(folderId: string | null): void {
	if (folderId === autoExpandFolderId) return;
	if (autoExpandTimer !== null) clearTimeout(autoExpandTimer);
	autoExpandTimer = null;
	autoExpandFolderId = folderId;
	if (!folderId) return;
	autoExpandTimer = setTimeout(() => {
		autoExpandTimer = null;
		folderActions.setCollapsed(folderId, false);
	}, AUTO_EXPAND_MS);
}

// Hover suppression, tooltips and the pager read the drag state off the document
// rather than importing this store, so the flag is mirrored onto the DOM here.
function publishDragActive(): void {
	if (typeof document === "undefined") return;
	const active = isSidebarDragActive();
	if (active === publishedDragActive) return;
	publishedDragActive = active;
	document.documentElement.classList.toggle("sidebar-dnd-active", active);
	document.body.classList.toggle("sidebar-dnd-active", active);
	document.dispatchEvent(new CustomEvent("lilo-sidebar-dnd-active-change"));
}

// Rows held in their dropped order for a beat after the commit (and the item kept out
// of every other zone), so nothing flashes back while the bridge patch is in flight.
let settled = $state<{ zoneId: string; itemId: string; items: SidebarDndItem[] } | null>(null);
let settleTimer: ReturnType<typeof setTimeout> | null = null;
let recentlyDroppedId = $state<string | null>(null);

function zoneRef(zoneId: string | null | undefined): SidebarZoneRef | null {
	if (!zoneId) return null;
	const meta = dndEngineStore.getZoneMeta(zoneId);
	if (!meta?.section) return null;
	return {
		id: zoneId,
		section: meta.section,
		parentFolderId: meta.parentFolderId ?? null,
	};
}

function isSidebarKind(kind: string): kind is BridgeSidebarItemKind {
	return kind === "tab" || kind === "folder";
}

// A folder zone owns the lower half of its own header row; when the pointer is in
// that band the row belongs at the top of the folder, not at the generic index the
// engine resolved from the child rects.
function resolvedTargetIndex(
	drag: DndActiveDrag,
	target: SidebarZoneRef,
	fallbackIndex: number,
): number {
	if (!target.parentFolderId) return fallbackIndex;
	const zoneRect = drag.target?.zoneRect;
	if (!zoneRect) return fallbackIndex;
	return folderDropIndex({
		pointY: drag.currentPoint.y,
		zoneTop: zoneRect.top,
		fallbackIndex,
	});
}

// Reads a sidebar-shaped snapshot out of an engine drag. Taken from the live drag
// while rendering, and from the drag the engine hands to onDrop at drop time: by
// then the engine has already cleared its own reference.
function snapshotFrom(drag: DndActiveDrag | null): SidebarDragSnapshot | null {
	if (!drag?.started) return null;
	if (!isSidebarKind(drag.source.item.kind)) return null;
	const source = zoneRef(drag.source.zoneId);
	if (!source) return null;
	const target = zoneRef(drag.target?.zoneId);
	const intoCollapsedFolder = target !== null &&
		dndEngineStore.getZoneMeta(target.id)?.isCollapsed === true;
	// A collapsed folder shows no rows to aim between: the tab goes last.
	const targetIndex = !target
		? 0
		: intoCollapsedFolder
			? Number.POSITIVE_INFINITY
			: resolvedTargetIndex(drag, target, drag.target?.index ?? 0);
	return {
		itemId: drag.source.item.id,
		kind: drag.source.item.kind,
		source,
		target,
		targetIndex,
		placeholder: intoCollapsedFolder
			? heldPlaceholder
			: target && { zone: target, index: targetIndex },
		intoCollapsedFolder,
	};
}

export function getSidebarDrag(): SidebarDragSnapshot | null {
	void dragVersion;
	return snapshotFrom(dndEngineStore.activeDrag);
}

export function isSidebarDragActive(): boolean {
	return getSidebarDrag() !== null;
}

export function getRecentlyDroppedId(): string | null {
	return recentlyDroppedId;
}

export function getZoneItems(
	zone: SidebarZoneRef,
	baseItems: readonly SidebarDndItem[],
): SidebarDndItem[] {
	if (settled) {
		if (settled.zoneId === zone.id) return settled.items;
		const { itemId } = settled;
		if (baseItems.some((item) => item.id === itemId)) {
			return baseItems.filter((item) => item.id !== itemId);
		}
	}
	return projectZoneItems(baseItems, zone, getSidebarDrag());
}

function clearSettleTimer(): void {
	if (settleTimer === null) return;
	clearTimeout(settleTimer);
	settleTimer = null;
}

export function resetSidebarDrag(): void {
	clearSettleTimer();
	settled = null;
}

// The one place a sidebar drop turns into a mutation. Zones call this from their
// drop callback; whichever zone the engine resolved as the target is the one that
// commits, so there is no per-zone ownership to arbitrate.
export function commitSidebarDrop(
	zone: SidebarZoneRef,
	baseItems: readonly SidebarDndItem[],
	commit: (payload: BridgeSidebarDropPayload) => void,
	activeDrag: DndActiveDrag,
): void {
	const drag = snapshotFrom(activeDrag);
	if (!drag?.target || drag.target.id !== zone.id) {
		resetSidebarDrag();
		return;
	}

	const projected = projectSidebarItemsWithShadow(
		baseItems,
		drag.itemId,
		drag.targetIndex,
		{ section: zone.section, parentFolderId: zone.parentFolderId },
		{ id: drag.itemId, kind: drag.kind },
	);
	const payload = commitFromDndProjection({
		draggedId: drag.itemId,
		items: projected,
		section: drag.target.section,
		parentFolderId: drag.target.parentFolderId,
	});
	if (!payload) {
		resetSidebarDrag();
		return;
	}

	const droppedId = drag.itemId;
	const settledItems = materializeSidebarProjection(projected, droppedId);
	// Dropped back where it started: nothing to commit.
	if (
		drag.source.id === zone.id &&
		settledItems.length === baseItems.length &&
		settledItems.every((item, index) => item.id === baseItems[index].id)
	) {
		resetSidebarDrag();
		return;
	}

	commit(payload);

	recentlyDroppedId = droppedId;
	settled = {
		zoneId: zone.id,
		itemId: droppedId,
		items: settledItems,
	};
	clearSettleTimer();
	settleTimer = setTimeout(() => {
		settleTimer = null;
		settled = null;
	}, DROP_SETTLE_MS);
	setTimeout(() => {
		if (recentlyDroppedId === droppedId) recentlyDroppedId = null;
	}, RECENT_DROP_MS);
}

export type { SidebarZoneRef };
