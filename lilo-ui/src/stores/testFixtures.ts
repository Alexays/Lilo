// Shared test fixtures for sidebar/tab store tests.
import type { BridgeTabSnapshot } from "../lib/bridge/protocol";

export function tab(
	id: string,
	spaceId: string,
	overrides: Partial<BridgeTabSnapshot> = {},
): BridgeTabSnapshot {
	return {
		id,
		spaceId,
		url: `https://example.com/${id}`,
		title: id,
		isLoading: false,
		canGoBack: false,
		canGoForward: false,
		progress: 1,
		isPinned: false,
		isBookmarked: false,
		isClosed: false,
		isAudioPlaying: false,
		isMuted: false,
		isMicrophoneActive: false,
		isMicrophoneMuted: false,
		isCameraActive: false,
		isScreenSharing: false,
		hasNavigationError: false,
		navigationErrorCode: 0,
		navigationErrorDomain: "",
		navigationErrorDescription: "",
		navigationErrorURL: "",
		...overrides,
	};
}

export function treeItem(
	itemId: string,
	spaceId: string,
	sortOrder: number,
	section: "bookmarked" | "pinned" | "unpinned" = "unpinned",
	kind: "tab" | "folder" = "tab",
	parentFolderId: string | null = null,
) {
	return {
		id: `${spaceId}-${itemId}-${section}`,
		spaceId,
		kind,
		itemId,
		parentFolderId,
		section,
		sortOrder,
	};
}
