import assert from "node:assert/strict";
import test from "node:test";

(globalThis as { window?: unknown }).window ??= {
	__liloBootstrapEvents: [],
};
type StateRune = (<T>(value: T) => T) & { raw: <T>(value: T) => T };
(globalThis as { $state?: StateRune }).$state ??= Object.assign(
	<T>(value: T) => value,
	{ raw: <T>(value: T) => value },
);

const { dndEngineStore } = await import("../lib/dndEngine/store.svelte");
type DndActiveDrag = import("../lib/dndEngine/store.svelte").DndActiveDrag;
const {
	commitSidebarDrop,
	getZoneItems,
	resetSidebarDrag,
} = await import("./sidebarDnd.svelte");
type SidebarZoneRef = import("./sidebarDnd.svelte").SidebarZoneRef;
type SidebarDndItem = import("../lib/dndEngine/adapters/sidebar").SidebarDndItem;

const DROP_SETTLE_MS = 180;

function elementRect(left: number, top: number, width: number, height: number): HTMLElement {
	return {
		getBoundingClientRect: () => ({
			left,
			top,
			right: left + width,
			bottom: top + height,
			width,
			height,
		}),
	} as HTMLElement;
}

const ZONE: SidebarZoneRef = { id: "zone-a", section: "unpinned", parentFolderId: null };
const OTHER_ZONE: SidebarZoneRef = { id: "zone-b", section: "pinned", parentFolderId: null };

function registerZones(): void {
	dndEngineStore.registerZone(elementRect(0, 0, 240, 120), {
		id: ZONE.id,
		axis: "vertical",
		meta: { section: "unpinned", parentFolderId: null },
	});
	dndEngineStore.registerZone(elementRect(0, 120, 240, 120), {
		id: OTHER_ZONE.id,
		axis: "vertical",
		meta: { section: "pinned", parentFolderId: null },
	});
}

function unregisterZones(): void {
	dndEngineStore.unregisterZone(ZONE.id);
	dndEngineStore.unregisterZone(OTHER_ZONE.id);
}

function baseItems(): SidebarDndItem[] {
	return [
		{ id: "tab-1", kind: "tab", section: "unpinned", parentFolderId: null },
		{ id: "tab-2", kind: "tab", section: "unpinned", parentFolderId: null },
	];
}

function dragOnto(zoneId: string, index = 1): DndActiveDrag {
	return {
		source: {
			item: { id: "tab-1", kind: "tab" },
			zoneId: ZONE.id,
			element: elementRect(0, 0, 240, 30),
			sourceRect: elementRect(0, 0, 240, 30).getBoundingClientRect() as DOMRect,
		},
		startPoint: { x: 10, y: 10 },
		currentPoint: { x: 10, y: 60 },
		target: { zoneId, index, axis: "vertical" },
		started: true,
	};
}

test("commitSidebarDrop skips the commit when the item lands where it started", () => {
	registerZones();
	resetSidebarDrag();

	let committed = 0;
	commitSidebarDrop(ZONE, baseItems(), () => {
		committed += 1;
	}, dragOnto(ZONE.id, 0));

	assert.equal(committed, 0);
	assert.deepEqual(
		getZoneItems(ZONE, baseItems()).map((item) => item.id),
		["tab-1", "tab-2"],
	);
	unregisterZones();
});

test("commitSidebarDrop ignores a drop on a zone that is not the drag target", () => {
	registerZones();
	resetSidebarDrag();

	let committed = 0;
	commitSidebarDrop(OTHER_ZONE, baseItems(), () => {
		committed += 1;
	}, dragOnto(ZONE.id));

	assert.equal(committed, 0);
	unregisterZones();
});

test("a committed drop holds the settled order for DROP_SETTLE_MS then releases", async () => {
	registerZones();
	resetSidebarDrag();

	let committed = 0;
	commitSidebarDrop(ZONE, baseItems(), () => {
		committed += 1;
	}, dragOnto(ZONE.id));
	assert.equal(committed, 1);

	assert.deepEqual(
		getZoneItems(ZONE, baseItems()).map((item) => item.id),
		["tab-2", "tab-1"],
		"the dropped order is held while the bridge patch is in flight",
	);

	await new Promise((resolve) => setTimeout(resolve, DROP_SETTLE_MS + 40));

	assert.deepEqual(
		getZoneItems(ZONE, baseItems()).map((item) => item.id),
		["tab-1", "tab-2"],
		"after the settle window the zone renders its base items again",
	);
	unregisterZones();
});

test("a cross-zone drop keeps the item out of its source zone while settling", () => {
	registerZones();
	resetSidebarDrag();

	const pinnedItems: SidebarDndItem[] = [
		{ id: "tab-9", kind: "tab", section: "pinned", parentFolderId: null },
	];
	let committed = 0;
	commitSidebarDrop(OTHER_ZONE, pinnedItems, () => {
		committed += 1;
	}, dragOnto(OTHER_ZONE.id, 1));
	assert.equal(committed, 1);

	assert.deepEqual(
		getZoneItems(OTHER_ZONE, pinnedItems).map((item) => item.id),
		["tab-9", "tab-1"],
	);
	assert.deepEqual(
		getZoneItems(ZONE, baseItems()).map((item) => item.id),
		["tab-2"],
		"the source zone must not show the dropped row again before the patch lands",
	);
	resetSidebarDrag();
	unregisterZones();
});

test("a new drag gesture releases the previous drop's hold", async () => {
	registerZones();
	resetSidebarDrag();
	commitSidebarDrop(ZONE, baseItems(), () => {}, dragOnto(ZONE.id));
	assert.deepEqual(getZoneItems(ZONE, baseItems()).map((item) => item.id), ["tab-2", "tab-1"]);

	dndEngineStore.startDrag({
		item: { id: "tab-2", kind: "tab" },
		zoneId: ZONE.id,
		element: elementRect(0, 0, 240, 30),
		sourceRect: elementRect(0, 0, 240, 30).getBoundingClientRect() as DOMRect,
	}, { x: 10, y: 10 });

	assert.deepEqual(getZoneItems(ZONE, baseItems()).map((item) => item.id), ["tab-1", "tab-2"]);

	dndEngineStore.drop();
	// endDrag defers its notification past the current task.
	await new Promise((resolve) => setTimeout(resolve, 0));
	unregisterZones();
});
