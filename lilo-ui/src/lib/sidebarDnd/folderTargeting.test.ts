import assert from "node:assert/strict";
import test from "node:test";
import {
	FOLDER_ROW_DROP_HEIGHT,
	folderDropIndex,
	folderZoneAcceptsPoint,
	rootZoneAcceptsPoint,
	type FolderTargetRow,
} from "./folderTargeting";

const ZONE_TOP = 100;
const BAND_START = ZONE_TOP + FOLDER_ROW_DROP_HEIGHT / 2;

function folderRow(overrides: Partial<FolderTargetRow> = {}): FolderTargetRow {
	return {
		id: "folder-1",
		top: ZONE_TOP,
		bottom: ZONE_TOP + FOLDER_ROW_DROP_HEIGHT,
		isFolder: true,
		isCollapsed: false,
		...overrides,
	};
}

test("an expanded folder claims everything below the upper half of its header", () => {
	const base = { zoneTop: ZONE_TOP, isCollapsed: false, dragKind: "tab" as const };
	assert.equal(folderZoneAcceptsPoint({ ...base, pointY: BAND_START - 1 }), false);
	assert.equal(folderZoneAcceptsPoint({ ...base, pointY: BAND_START + 1 }), true);
	// The gap before the first child, an empty-folder placeholder, the drop placeholder.
	assert.equal(folderZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 31 }), true);
	assert.equal(folderZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 400 }), true);
});

test("a locked folder accepts no drop anywhere", () => {
	const base = { zoneTop: ZONE_TOP, isCollapsed: true, refusesDrag: true, dragKind: "tab" as const };
	assert.equal(folderZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 15 }), false);
	assert.equal(folderZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 400 }), false);
});

test("a collapsed folder claims only the middle of its header", () => {
	const base = { zoneTop: ZONE_TOP, isCollapsed: true, dragKind: "tab" as const };
	assert.equal(folderZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 15 }), true);
	assert.equal(folderZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 2 }), false);
	assert.equal(folderZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 28 }), false);
});

test("folder zones take folders as well as tabs, but no spaces or layers", () => {
	const base = { pointY: BAND_START + 1, zoneTop: ZONE_TOP, isCollapsed: false };
	assert.equal(folderZoneAcceptsPoint({ ...base, dragKind: "folder" }), true);
	assert.equal(folderZoneAcceptsPoint({ ...base, dragKind: "space" }), false);
	assert.equal(folderZoneAcceptsPoint({ ...base, dragKind: "layer" }), false);
});

test("an expanded folder yields a subfolder's band to it, refused or not", () => {
	const rows = [folderRow({ id: "sub", top: ZONE_TOP + 60, bottom: ZONE_TOP + 60 + FOLDER_ROW_DROP_HEIGHT, isCollapsed: true })];
	const base = { zoneTop: ZONE_TOP, isCollapsed: false, dragKind: "folder" as const, rows };
	assert.equal(folderZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 62 }), true);
	assert.equal(folderZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 75 }), false);
	assert.equal(folderZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 88 }), true);
});

test("an open folder's end band is the slot after it, in the list around it", () => {
	const zoneBottom = ZONE_TOP + 120;
	const tabRows = [folderRow({ id: "tab", top: ZONE_TOP + 90, bottom: zoneBottom, isFolder: false })];
	const base = { zoneTop: ZONE_TOP, zoneBottom, isCollapsed: false, dragKind: "tab" as const };
	assert.equal(folderZoneAcceptsPoint({ ...base, rows: tabRows, pointY: zoneBottom - 7 }), true);
	assert.equal(folderZoneAcceptsPoint({ ...base, rows: tabRows, pointY: zoneBottom - 3 }), false);

	// The parent whose last row is that open folder takes the band.
	const subfolder = folderRow({ id: "sub", top: ZONE_TOP + 30, bottom: zoneBottom });
	assert.equal(folderZoneAcceptsPoint({ ...base, rows: [subfolder], pointY: zoneBottom - 7 }), false);
	assert.equal(folderZoneAcceptsPoint({ ...base, rows: [subfolder], pointY: zoneBottom - 3 }), true);
	assert.equal(rootZoneAcceptsPoint({ rows: [subfolder], dragKind: "tab", pointY: zoneBottom - 3 }), true);
});

test("folder drop index pins the header band to the first slot", () => {
	const base = { zoneTop: ZONE_TOP, fallbackIndex: 4 };
	assert.equal(folderDropIndex({ ...base, pointY: BAND_START + 1 }), 0);
	assert.equal(folderDropIndex({ ...base, pointY: ZONE_TOP + 60 }), 4);
});

test("root zone yields an expanded folder below the upper half of its header", () => {
	const rows = [folderRow({ bottom: ZONE_TOP + 200 })];
	const base = { rows, dragKind: "tab" as const };
	assert.equal(rootZoneAcceptsPoint({ ...base, pointY: BAND_START - 1 }), true);
	assert.equal(rootZoneAcceptsPoint({ ...base, pointY: BAND_START + 1 }), false);
	assert.equal(rootZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 150 }), false);
	assert.equal(rootZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 210 }), true);
});

test("root zone keeps the edges of a collapsed folder row", () => {
	const rows = [folderRow({ isCollapsed: true })];
	const base = { rows, dragKind: "tab" as const };
	assert.equal(rootZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 2 }), true);
	assert.equal(rootZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 15 }), false);
	assert.equal(rootZoneAcceptsPoint({ ...base, pointY: ZONE_TOP + 28 }), true);
});

test("root zone leaves a folder's band to folder drags too and rejects spaces and layers", () => {
	const rows = [folderRow()];
	assert.equal(rootZoneAcceptsPoint({ pointY: BAND_START + 1, rows, dragKind: "folder" }), false);
	assert.equal(rootZoneAcceptsPoint({ pointY: BAND_START - 1, rows, dragKind: "folder" }), true);
	assert.equal(rootZoneAcceptsPoint({ pointY: BAND_START - 1, rows, dragKind: "space" }), false);
	assert.equal(rootZoneAcceptsPoint({ pointY: BAND_START - 1, rows, dragKind: "layer" }), false);
});
