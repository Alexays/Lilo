import type {
	BridgeProfileSnapshot,
	BridgeSpaceSnapshot,
	BridgeTabFolderSnapshot,
} from "./protocol";
import {
	DEFAULT_ACCENT_COLOR,
	DEFAULT_PROFILE_NAME,
	DEFAULT_SPACE_ICON,
	DEFAULT_SPACE_NAME,
} from "./defaults";

export function coerceSpaceSnapshot(
	data: BridgeSpaceSnapshot,
): BridgeSpaceSnapshot {
	return {
		id: data.id,
		name: data.name || DEFAULT_SPACE_NAME,
		icon: data.icon || DEFAULT_SPACE_ICON,
		color: data.color || DEFAULT_ACCENT_COLOR,
		profileId: data.profileId || "",
		isPrivate: data.isPrivate ?? false,
		sortOrder: data.sortOrder ?? 0,
		archiveAfterHours: data.archiveAfterHours ?? 12,
		colorMode: data.colorMode ?? "fixed",
	};
}

export function coerceProfileSnapshot(
	data: BridgeProfileSnapshot,
): BridgeProfileSnapshot {
	return {
		id: data.id,
		name: data.name || DEFAULT_PROFILE_NAME,
		isDefault: data.isDefault ?? false,
		color: data.color || DEFAULT_ACCENT_COLOR,
	};
}

export function coerceTabFolderSnapshot(
	data: Partial<BridgeTabFolderSnapshot> & { id: string; spaceId: string },
): BridgeTabFolderSnapshot {
	return {
		id: data.id,
		spaceId: data.spaceId,
		name: data.name || "New Folder",
		color: data.color || DEFAULT_ACCENT_COLOR,
		isCollapsed: data.isCollapsed ?? false,
		isSplit: data.isSplit ?? false,
		isLocked: data.isLocked ?? false,
		lock: data.lock ?? null,
		...(data.splitLayout && { splitLayout: data.splitLayout }),
	};
}
