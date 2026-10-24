import assert from "node:assert/strict";
import test from "node:test";
import { MOTION } from "../motion/timings";
import {
	commitFromDndProjection,
	dndItemsForFolderTabs,
	dndItemsForSidebarItems,
	flipDurationForSidebarDndItem,
	materializeSidebarProjection,
	projectSidebarItemsWithShadow,
	projectZoneItems,
	sidebarDndKey,
	type SidebarDragSnapshot,
	type SidebarZoneRef,
} from "./adapters/sidebar";
import { isShadowItem } from "./projection";

test("projectSidebarItemsWithShadow reorders root tabs with a custom placeholder", () => {
	const items = dndItemsForSidebarItems([
		{ id: "a", kind: "tab" },
		{ id: "b", kind: "tab" },
	], "unpinned");
	const projected = projectSidebarItemsWithShadow(items, "b", 0, {
		section: "unpinned",
		parentFolderId: null,
	});

	assert.deepEqual(projected.map((item) => item.id), ["dnd-shadow:b", "a"]);
	assert.equal(isShadowItem(projected[0]), true);
	assert.equal(sidebarDndKey(projected[0]), "dnd-shadow:b:shadow");
});

test("projectSidebarItemsWithShadow moves a tab into a folder target", () => {
	const items = dndItemsForFolderTabs([{ id: "existing" }], "unpinned", "folder-a");
	const projected = projectSidebarItemsWithShadow(items, "tab-a", 1, {
		section: "unpinned",
		parentFolderId: "folder-a",
	});

	assert.deepEqual(projected.map((item) => item.id), ["existing", "dnd-shadow:tab-a"]);
	assert.equal(projected[1].parentFolderId, "folder-a");
});

test("a folder dropped into a folder commits as a folder insert under it", () => {
	const items = dndItemsForSidebarItems([{ id: "tab-a", kind: "tab" }], "unpinned", "folder-b");
	const projected = projectSidebarItemsWithShadow(items, "folder-a", 1, {
		section: "unpinned",
		parentFolderId: "folder-b",
	}, { id: "folder-a", kind: "folder" });

	assert.deepEqual(projected.map((item) => item.id), ["tab-a", "dnd-shadow:folder-a"]);
	assert.deepEqual(commitFromDndProjection({
		draggedId: "folder-a",
		items: projected,
		section: "unpinned",
		parentFolderId: "folder-b",
	}), {
		type: "insert",
		kind: "folder",
		id: "folder-a",
		section: "unpinned",
		parentFolderId: "folder-b",
		fallbackIndex: 1,
		insertBeforeId: null,
		insertAfterId: "tab-a",
	});
});

test("projectSidebarItemsWithShadow keeps folders out of the bookmarks", () => {
	const items = dndItemsForFolderTabs([{ id: "tab-a" }]);

	assert.deepEqual(projectSidebarItemsWithShadow(items, "folder-a", 0, {
		section: "bookmarked",
		parentFolderId: null,
	}, { id: "folder-a", kind: "folder" }), items);
});

test("projectSidebarItemsWithShadow preserves source folder kind across root zones", () => {
	const items = dndItemsForSidebarItems([{ id: "tab-a", kind: "tab" }], "pinned");
	const projected = projectSidebarItemsWithShadow(items, "folder-a", 0, {
		section: "pinned",
		parentFolderId: null,
	}, {
		id: "folder-a",
		kind: "folder",
	});

	assert.equal(projected[0].kind, "folder");
	assert.equal(projected[0].id, "dnd-shadow:folder-a");
});

test("commitFromDndProjection emits bridge insert anchors", () => {
	const projected = projectSidebarItemsWithShadow(
		dndItemsForSidebarItems([
			{ id: "a", kind: "tab" },
			{ id: "b", kind: "folder" },
		], "pinned"),
		"b",
		0,
		{ section: "pinned", parentFolderId: null },
	);

	assert.deepEqual(commitFromDndProjection({
		draggedId: "b",
		items: projected,
		section: "pinned",
		parentFolderId: null,
	}), {
		type: "insert",
		kind: "folder",
		id: "b",
		section: "pinned",
		parentFolderId: null,
		fallbackIndex: 0,
		insertBeforeId: "a",
		insertAfterId: null,
	});
});

test("flipDurationForSidebarDndItem animates in-flow placeholders during drag FLIP", () => {
	const [shadow] = projectSidebarItemsWithShadow(
		dndItemsForSidebarItems([{ id: "tab-a", kind: "tab" }], "unpinned"),
		"tab-a",
		0,
		{ section: "unpinned", parentFolderId: null },
	);

	assert.equal(flipDurationForSidebarDndItem(shadow, { itemCount: 2 }), MOTION.reorderMs);
	assert.equal(
		flipDurationForSidebarDndItem({ id: "tab-a" }, { itemCount: 2 }),
		MOTION.reorderMs,
	);
});

test("flipDurationForSidebarDndItem suppresses FLIP for the recently dropped item", () => {
	assert.equal(
		flipDurationForSidebarDndItem({ id: "tab-a" }, { recentlyDraggedId: "tab-a", itemCount: 2 }),
		0,
	);
	assert.equal(
		flipDurationForSidebarDndItem({ id: "tab-b" }, { recentlyDraggedId: "tab-a", itemCount: 2 }),
		MOTION.reorderMs,
	);
});

test("flipDurationForSidebarDndItem disables FLIP above the item-count threshold", () => {
	assert.equal(
		flipDurationForSidebarDndItem({ id: "tab-a" }, { itemCount: 60 }),
		MOTION.reorderMs,
	);
	assert.equal(
		flipDurationForSidebarDndItem({ id: "tab-a" }, { itemCount: 61 }),
		0,
	);
});

test("materializeSidebarProjection replaces the drop shadow with the real dragged item", () => {
	const projected = projectSidebarItemsWithShadow(
		dndItemsForSidebarItems([{ id: "tab-a", kind: "tab" }], "unpinned"),
		"tab-b",
		0,
		{ section: "unpinned", parentFolderId: null },
		{ id: "tab-b", kind: "tab" },
	);

	assert.deepEqual(
		materializeSidebarProjection(projected, "tab-b").map((item) => item.id),
		["tab-b", "tab-a"],
	);
	assert.equal(materializeSidebarProjection(projected, "tab-b")[0].section, "unpinned");
});

const ROOT: SidebarZoneRef = {
	id: "root-unpinned",
	section: "unpinned",
	parentFolderId: null,
};
const PINNED: SidebarZoneRef = {
	id: "root-pinned",
	section: "pinned",
	parentFolderId: null,
};
const FOLDER: SidebarZoneRef = {
	id: "folder-a",
	section: "unpinned",
	parentFolderId: "folder-a",
};

function zoneTab(id: string, zone: SidebarZoneRef) {
	return { id, kind: "tab" as const, section: zone.section, parentFolderId: zone.parentFolderId };
}

function drag(overrides: Partial<SidebarDragSnapshot> = {}): SidebarDragSnapshot {
	const target = overrides.target ?? ROOT;
	const targetIndex = overrides.targetIndex ?? 0;
	return {
		itemId: "t2",
		kind: "tab",
		source: ROOT,
		target,
		targetIndex,
		placeholder: { zone: target, index: targetIndex },
		intoCollapsedFolder: false,
		...overrides,
	};
}

const rootItems = [zoneTab("t1", ROOT), zoneTab("t2", ROOT), zoneTab("t3", ROOT)];

test("projectZoneItems: no drag leaves a zone's rows untouched", () => {
	assert.deepEqual(projectZoneItems(rootItems, ROOT, null), rootItems);
});

test("projectZoneItems: the target zone gets a shadow at the resolved index", () => {
	const projected = projectZoneItems(rootItems, ROOT, drag({ targetIndex: 0 }));
	assert.equal(projected.length, 3);
	assert.equal(isShadowItem(projected[0]), true);
	assert.deepEqual(projected.slice(1).map((item) => item.id), ["t1", "t3"]);
});

test("projectZoneItems: a non-target zone lifts the dragged row out", () => {
	const projected = projectZoneItems(rootItems, ROOT, drag({ target: PINNED }));
	assert.deepEqual(projected.map((item) => item.id), ["t1", "t3"]);
	assert.equal(projected.some(isShadowItem), false);
});

test("projectZoneItems: a held placeholder stays put while a collapsed folder is the target", () => {
	const active = drag({
		target: FOLDER,
		targetIndex: Number.POSITIVE_INFINITY,
		placeholder: { zone: ROOT, index: 1 },
		intoCollapsedFolder: true,
	});
	const rootProjection = projectZoneItems(rootItems, ROOT, active);
	assert.equal(isShadowItem(rootProjection[1]), true);
	assert.deepEqual(projectZoneItems([zoneTab("c1", FOLDER)], FOLDER, active).map((item) => item.id), ["c1"]);
});

test("commit resolves mid-list anchors from the projected order", () => {
	// The index addresses the list with the dragged row already lifted out ([t1, t3]),
	// so 1 lands between them.
	const active = drag({ targetIndex: 1 });
	const projected = projectZoneItems(rootItems, ROOT, active);
	const commit = commitFromDndProjection({
		draggedId: active.itemId,
		items: projected,
		section: "unpinned",
		parentFolderId: null,
	});
	assert.ok(commit !== null && commit.type === "insert");
	assert.equal(commit.id, "t2");
	assert.equal(commit.insertAfterId, "t1");
	assert.equal(commit.insertBeforeId, "t3");
});

test("commit into a folder carries the parent folder id", () => {
	const active = drag({ target: FOLDER, targetIndex: 0 });
	const projected = projectZoneItems([zoneTab("c1", FOLDER)], FOLDER, active);
	const commit = commitFromDndProjection({
		draggedId: active.itemId,
		items: projected,
		section: FOLDER.section,
		parentFolderId: FOLDER.parentFolderId,
	});
	assert.ok(commit !== null && commit.type === "insert");
	assert.equal(commit.parentFolderId, "folder-a");
	assert.equal(commit.insertBeforeId, "c1");
});
