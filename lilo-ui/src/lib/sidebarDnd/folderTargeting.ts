import type { DndItemKind } from "../dndEngine/types";

// A folder header's upper half stays with the list around it (drop above the folder); the rest of
// an expanded folder is the folder's, a collapsed one only claims its header's middle.
export const FOLDER_ROW_DROP_HEIGHT = 30;
const COLLAPSED_BAND_INSET = 8;
// The bottom of an open folder is the slot after it, in the list around it: without it an open
// folder last in its list leaves nowhere to drop after it.
const FOLDER_END_BAND = 6;

export type FolderTargetRow = {
	id: string;
	top: number;
	bottom: number;
	isFolder: boolean;
	isCollapsed: boolean;
};

function isInsideCollapsedBand(pointY: number, rowTop: number): boolean {
	return pointY >= rowTop + COLLAPSED_BAND_INSET &&
		pointY <= rowTop + FOLDER_ROW_DROP_HEIGHT - COLLAPSED_BAND_INSET;
}

/** Whether the point is in a child folder row's own drop band, which that folder's zone takes. */
function isInsideFolderBand(pointY: number, rows: readonly FolderTargetRow[]): boolean {
	const folderRow = rows.find((row) =>
		row.isFolder && pointY >= row.top && pointY <= row.bottom
	);
	if (!folderRow) return false;
	if (folderRow.isCollapsed) return isInsideCollapsedBand(pointY, folderRow.top);
	return pointY >= folderRow.top + FOLDER_ROW_DROP_HEIGHT / 2 && pointY < folderRow.bottom - FOLDER_END_BAND;
}

// A refused folder band stays refused: the zone around it does not take the drop instead, so
// the drag shows no target there.
export function folderZoneAcceptsPoint({
	pointY,
	zoneTop,
	zoneBottom = Number.POSITIVE_INFINITY,
	isCollapsed,
	refusesDrag = false,
	dragKind,
	rows = [],
}: {
	pointY: number;
	zoneTop: number;
	zoneBottom?: number;
	isCollapsed: boolean;
	refusesDrag?: boolean;
	dragKind: DndItemKind;
	rows?: readonly FolderTargetRow[];
}): boolean {
	if ((dragKind !== "tab" && dragKind !== "folder") || refusesDrag) return false;
	if (isCollapsed) return isInsideCollapsedBand(pointY, zoneTop);
	if (pointY < zoneTop + FOLDER_ROW_DROP_HEIGHT / 2 || isInsideFolderBand(pointY, rows)) return false;
	// A last row that is itself an open folder ends here too: its end band is this folder's to take.
	const last = rows.at(-1);
	const endsInOpenFolder = last?.isFolder === true && !last.isCollapsed && last.bottom >= zoneBottom - 1;
	return endsInOpenFolder || pointY < zoneBottom - FOLDER_END_BAND;
}

export function folderDropIndex({
	pointY,
	zoneTop,
	fallbackIndex,
}: {
	pointY: number;
	zoneTop: number;
	fallbackIndex: number;
}): number {
	return pointY <= zoneTop + FOLDER_ROW_DROP_HEIGHT ? 0 : fallbackIndex;
}

export function rootZoneAcceptsPoint({
	pointY,
	rows,
	dragKind,
}: {
	pointY: number;
	rows: readonly FolderTargetRow[];
	dragKind: DndItemKind;
}): boolean {
	if (dragKind !== "tab" && dragKind !== "folder") return false;
	return !isInsideFolderBand(pointY, rows);
}
