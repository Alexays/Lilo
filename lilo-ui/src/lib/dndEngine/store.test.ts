import assert from "node:assert/strict";
import test from "node:test";
import { DndEngineStore } from "./store.svelte";

function targetWithoutZoneRect(
	target: ReturnType<DndEngineStore["updatePointer"]>,
): Record<string, unknown> | null {
	if (!target) return null;
	const { zoneRect: _zoneRect, ...rest } = target;
	return rest;
}

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

function mutableElementRect(
	rect: { left: number; top: number; width: number; height: number },
	reads: { count: number },
): HTMLElement {
	return {
		getBoundingClientRect: () => {
			reads.count += 1;
			return {
				left: rect.left,
				top: rect.top,
				right: rect.left + rect.width,
				bottom: rect.top + rect.height,
				width: rect.width,
				height: rect.height,
			};
		},
	} as HTMLElement;
}

test("DndEngineStore resolves nested zones before broader parent zones", () => {
	const store = new DndEngineStore();
	store.registerZone(elementRect(0, 0, 240, 180), {
		id: "root",
		axis: "vertical",
		getItems: () => [],
	});
	store.registerZone(elementRect(12, 40, 216, 72), {
		id: "folder",
		axis: "vertical",
		getItems: () => [],
	});
	store.startDrag({
		item: { id: "tab-a", kind: "tab" },
		zoneId: "root",
		element: elementRect(0, 0, 240, 30),
		sourceRect: elementRect(0, 0, 240, 30).getBoundingClientRect(),
	}, { x: 10, y: 10 });

	assert.equal(store.updatePointer({ x: 24, y: 52 }, true)?.zoneId, "folder");
});

test("DndEngineStore never resolves a zone from another space", () => {
	const store = new DndEngineStore();
	store.registerZone(elementRect(0, 0, 240, 100), {
		id: "root-a",
		axis: "vertical",
		meta: { section: "unpinned", spaceId: "space-a", parentFolderId: null },
		getItems: () => [],
	});
	// A hidden neighbour pane overlapping the page area below the active list.
	store.registerZone(elementRect(0, 100, 240, 100), {
		id: "root-b",
		axis: "vertical",
		meta: { section: "unpinned", spaceId: "space-b", parentFolderId: null },
		getItems: () => [],
	});
	store.startDrag({
		item: { id: "tab-a", kind: "tab" },
		zoneId: "root-a",
		element: elementRect(0, 0, 240, 30),
		sourceRect: elementRect(0, 0, 240, 30).getBoundingClientRect(),
	}, { x: 10, y: 10 });

	assert.equal(store.updatePointer({ x: 10, y: 150 }, true), null);
	assert.equal(store.updatePointer({ x: 10, y: 50 }, true)?.zoneId, "root-a");
});

test("DndEngineStore ignores shadow placeholders when resolving item geometry", () => {
	const store = new DndEngineStore();
	store.registerZone(elementRect(0, 0, 240, 120), {
		id: "folder",
		axis: "vertical",
		getItems: () => [
			{ id: "dnd-shadow:tab-a", kind: "tab" },
			{ id: "child-a", kind: "tab" },
		],
	});
	store.registerItem(elementRect(0, 30, 240, 30), {
		item: { id: "dnd-shadow:tab-a", kind: "tab" },
		zoneId: "folder",
	});
	store.registerItem(elementRect(0, 63, 240, 30), {
		item: { id: "child-a", kind: "tab" },
		zoneId: "folder",
	});
	store.startDrag({
		item: { id: "tab-a", kind: "tab" },
		zoneId: "root",
		element: elementRect(0, 0, 240, 30),
		sourceRect: elementRect(0, 0, 240, 30).getBoundingClientRect(),
	}, { x: 10, y: 10 });

	assert.deepEqual(targetWithoutZoneRect(store.updatePointer({ x: 20, y: 40 }, true)), {
		zoneId: "folder",
		index: 0,
		axis: "vertical",
	});
});

test("DndEngineStore re-measures after a reprojection and keeps the same target", () => {
	const store = new DndEngineStore();
	const firstRect = { left: 0, top: 0, width: 240, height: 30 };
	const secondRect = { left: 0, top: 34, width: 240, height: 30 };
	const reads = { count: 0 };
	let items = [
		{ id: "tab-a", kind: "tab" as const },
		{ id: "tab-b", kind: "tab" as const },
	];

	store.registerZone(elementRect(0, 0, 240, 160), {
		id: "root",
		axis: "vertical",
		getItems: () => items,
	});
	store.registerItem(mutableElementRect(firstRect, reads), {
		item: { id: "tab-a", kind: "tab" },
		zoneId: "root",
	});
	store.registerItem(mutableElementRect(secondRect, reads), {
		item: { id: "tab-b", kind: "tab" },
		zoneId: "root",
	});
	store.startDrag({
		item: { id: "tab-dragged", kind: "tab" },
		zoneId: "other",
		element: elementRect(0, 200, 240, 30),
		sourceRect: elementRect(0, 200, 240, 30).getBoundingClientRect(),
	}, { x: 10, y: 210 });

	const pointer = { x: 20, y: 24 };
	assert.equal(store.updatePointer(pointer, true)?.index, 1);

	// The placeholder mounts between the two rows and pushes tab-b down.
	items = [items[0], { id: "dnd-shadow:tab-dragged", kind: "tab" as const }, items[1]];
	secondRect.top = 68;
	const measuresBefore = store.measureCount;

	assert.equal(store.updatePointer(pointer, true)?.index, 1);
	assert.equal(store.measureCount, measuresBefore + 1, "a new target re-measures the layout once");
	assert.equal(store.updatePointer({ x: 20, y: 60 }, true)?.index, 1, "the pointer over the placeholder keeps it");
	assert.equal(store.measureCount, measuresBefore + 1, "an unchanged target keeps the cached layout");
});

test("DndEngineStore measures without the dragged row before its placeholder lands", () => {
	const store = new DndEngineStore();
	const items = [
		{ id: "tab-a", kind: "tab" as const },
		{ id: "tab-dragged", kind: "tab" as const },
		{ id: "tab-b", kind: "tab" as const },
	];
	store.registerZone(elementRect(0, 0, 240, 120), {
		id: "root",
		axis: "vertical",
		getItems: () => items,
	});
	items.forEach((item, index) => {
		store.registerItem(elementRect(0, index * 33, 240, 30), { item, zoneId: "root" });
	});
	store.startDrag({
		item: items[1],
		zoneId: "root",
		element: elementRect(0, 33, 240, 30),
		sourceRect: elementRect(0, 33, 240, 30).getBoundingClientRect(),
	}, { x: 10, y: 40 });

	// Below the dragged row's own midpoint is still its slot: index 1 of [tab-a, tab-b].
	assert.equal(store.updatePointer({ x: 10, y: 54 }, true)?.index, 1);
});

test("DndEngineStore resolves insertion from the pointer", () => {
	const store = new DndEngineStore();
	store.registerZone(elementRect(0, 0, 240, 400), {
		id: "root",
		axis: "vertical",
		getItems: () => [{ id: "tab-a", kind: "tab" }],
	});
	store.registerItem(elementRect(0, 0, 240, 30), {
		item: { id: "tab-a", kind: "tab" },
		zoneId: "root",
	});
	// A tall source (an expanded folder) grabbed by its header.
	store.startDrag({
		item: { id: "folder-b", kind: "folder" },
		zoneId: "root",
		element: elementRect(0, 80, 240, 300),
		sourceRect: elementRect(0, 80, 240, 300).getBoundingClientRect(),
	}, { x: 10, y: 90 });

	assert.equal(store.updatePointer({ x: 10, y: 8 }, true)?.index, 0);
});

test("DndEngineStore measures nothing before the drag starts", () => {
	const store = new DndEngineStore();
	const reads = { count: 0 };
	store.registerZone(mutableElementRect({ left: 0, top: 0, width: 240, height: 160 }, reads), {
		id: "root",
		axis: "vertical",
		getItems: () => [],
	});
	store.startDrag({
		item: { id: "tab-a", kind: "tab" },
		zoneId: "root",
		element: elementRect(0, 0, 240, 30),
		sourceRect: elementRect(0, 0, 240, 30).getBoundingClientRect(),
	}, { x: 10, y: 10 });

	assert.equal(store.updatePointer({ x: 11, y: 11 }, false), null);
	assert.equal(reads.count, 0);
	assert.equal(store.updatePointer({ x: 10, y: 40 }, true)?.zoneId, "root");
	assert.ok(reads.count > 0);
});

test("DndEngineStore resolves from cached layout until the target changes or it is invalidated", () => {
	const store = new DndEngineStore();
	const zoneReads = { count: 0 };
	const itemReads = { count: 0 };
	const zoneRect = { left: 0, top: 0, width: 240, height: 160 };
	const itemRect = { left: 0, top: 0, width: 240, height: 40 };

	store.registerZone(mutableElementRect(zoneRect, zoneReads), {
		id: "root",
		axis: "vertical",
		getItems: () => [{ id: "tab-a", kind: "tab" }],
	});
	store.registerItem(mutableElementRect(itemRect, itemReads), {
		item: { id: "tab-a", kind: "tab" },
		zoneId: "root",
	});
	store.startDrag({
		item: { id: "tab-b", kind: "tab" },
		zoneId: "root",
		element: elementRect(0, 80, 240, 30),
		sourceRect: elementRect(0, 80, 240, 30).getBoundingClientRect(),
	}, { x: 10, y: 90 });

	assert.equal(store.updatePointer({ x: 10, y: 90 }, true)?.index, 1);
	// The first target re-measures once; after that the same target reads the cache.
	assert.equal(store.updatePointer({ x: 10, y: 90 }, true)?.index, 1);
	const readsAfterSettle = zoneReads.count + itemReads.count;

	itemRect.top = 90;

	assert.equal(
		store.updatePointer({ x: 10, y: 90 }, true)?.index,
		1,
		"cached geometry should keep the previous item position until invalidation",
	);
	assert.equal(zoneReads.count + itemReads.count, readsAfterSettle);

	store.invalidateLayoutSnapshot();

	assert.equal(store.updatePointer({ x: 10, y: 90 }, true)?.index, 0);
	assert.ok(
		zoneReads.count + itemReads.count > readsAfterSettle,
		"invalidating the snapshot should trigger one fresh measurement pass",
	);
});

test("DndEngineStore holds the last target across a gap between zones", () => {
	const store = new DndEngineStore();
	store.registerZone(elementRect(0, 0, 240, 100), {
		id: "pinned",
		axis: "vertical",
		getItems: () => [],
	});
	store.registerZone(elementRect(0, 120, 240, 100), {
		id: "unpinned",
		axis: "vertical",
		getItems: () => [],
	});
	store.startDrag({
		item: { id: "tab-a", kind: "tab" },
		zoneId: "unpinned",
		element: elementRect(0, 120, 240, 30),
		sourceRect: elementRect(0, 120, 240, 30).getBoundingClientRect(),
	}, { x: 10, y: 130 });

	assert.equal(store.updatePointer({ x: 10, y: 90 }, true)?.zoneId, "pinned");
	assert.equal(store.updatePointer({ x: 10, y: 110 }, true)?.zoneId, "pinned", "inside the gap");
	assert.equal(store.updatePointer({ x: 10, y: 140 }, true)?.zoneId, "unpinned");
	assert.equal(store.updatePointer({ x: 400, y: 140 }, true), null, "far outside every zone");
});

test("DndEngineStore does not hold a target over a zone that refuses the point", () => {
	const store = new DndEngineStore();
	store.registerZone(elementRect(0, 0, 240, 100), {
		id: "list",
		axis: "vertical",
		getItems: () => [],
	});
	store.registerZone(elementRect(0, 104, 240, 40), {
		id: "bar",
		axis: "horizontal",
		getItems: () => [],
		canResolve: () => false,
	});
	store.startDrag({
		item: { id: "tab-a", kind: "tab" },
		zoneId: "list",
		element: elementRect(0, 0, 240, 30),
		sourceRect: elementRect(0, 0, 240, 30).getBoundingClientRect(),
	}, { x: 10, y: 10 });

	assert.equal(store.updatePointer({ x: 10, y: 90 }, true)?.zoneId, "list");
	assert.equal(store.updatePointer({ x: 10, y: 110 }, true), null);
});

test("DndEngineStore stamps the resolved zone rect onto the target", () => {
	const store = new DndEngineStore();
	store.registerZone(elementRect(0, 40, 240, 120), {
		id: "folder",
		axis: "vertical",
		getItems: () => [],
	});
	store.startDrag({
		item: { id: "tab-a", kind: "tab" },
		zoneId: "root",
		element: elementRect(0, 0, 240, 30),
		sourceRect: elementRect(0, 0, 240, 30).getBoundingClientRect(),
	}, { x: 10, y: 10 });

	assert.equal(store.updatePointer({ x: 20, y: 60 }, true)?.zoneRect?.top, 40);
});

// getItems() reads the resolved target without getZoneSnapshot(), which would re-measure zones
// by invoking getItems() again.
test("DndEngineStore lets getItems read the active target without re-entering", () => {
	const store = new DndEngineStore();
	let getItemsDepth = 0;
	let maxDepth = 0;
	store.registerZone(elementRect(0, 0, 240, 120), {
		id: "root",
		axis: "vertical",
		getItems: () => {
			getItemsDepth += 1;
			maxDepth = Math.max(maxDepth, getItemsDepth);
			// What a projected zone does: interpret the target using only the rect
			// the store stamped on it.
			void store.activeDrag?.target?.zoneRect?.top;
			getItemsDepth -= 1;
			return [];
		},
	});
	store.startDrag({
		item: { id: "tab-a", kind: "tab" },
		zoneId: "root",
		element: elementRect(0, 0, 240, 30),
		sourceRect: elementRect(0, 0, 240, 30).getBoundingClientRect(),
	}, { x: 10, y: 10 });

	store.updatePointer({ x: 20, y: 60 }, true);
	assert.equal(maxDepth, 1);
});

// drop() clears the drag before the drop callbacks run, but observers must not learn
// the drag ended until the whole pointerup dispatch is over: a listener that unregisters
// itself on "drag ended" would otherwise miss the same pointerup and lose a cross-zone drop.
test("DndEngineStore defers the drag-end notification past the current task", async () => {
	const store = new DndEngineStore();
	const notifications: string[] = [];
	store.subscribe(() => notifications.push(store.activeDrag ? "active" : "ended"));
	store.registerZone(elementRect(0, 0, 240, 120), {
		id: "root",
		axis: "vertical",
		getItems: () => [],
	});
	store.startDrag({
		item: { id: "tab-a", kind: "tab" },
		zoneId: "root",
		element: elementRect(0, 0, 240, 30),
		sourceRect: elementRect(0, 0, 240, 30).getBoundingClientRect(),
	}, { x: 10, y: 10 });
	store.updatePointer({ x: 20, y: 60 }, true);
	notifications.length = 0;

	store.drop();
	// Still nothing, not even after a microtask checkpoint, which the DOM runs
	// between two listeners on the same event.
	await Promise.resolve();
	assert.deepEqual(notifications, []);

	await new Promise((resolve) => setTimeout(resolve, 0));
	assert.deepEqual(notifications, ["ended"]);
});

test("DndEngineStore keeps an item's new node when its old node unmounts after it", () => {
	const store = new DndEngineStore();
	const item = { id: "folder-a", kind: "folder" as const };
	store.registerZone(elementRect(0, 0, 300, 32), { id: "pinned", axis: "horizontal", getItems: () => [item] });
	const oldNode = elementRect(400, 0, 80, 32);
	const newNode = elementRect(0, 0, 80, 32);
	store.registerItem(oldNode, { item, zoneId: "today" });
	store.registerItem(newNode, { item, zoneId: "pinned" });
	store.unregisterItem(item.id, oldNode);

	assert.deepEqual(store.getZoneSnapshot("pinned")?.items.map((entry) => entry.rect.left), [0]);
});
