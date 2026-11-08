// The one closed folder whose tabs show beside the sidebar. A short rest of the pointer on its row
// opens it, and it stays up while the pointer crosses from the row to the popover.

const PEEK_DELAY_MS = 450;
const PEEK_LEAVE_GRACE_MS = 250;

let peek = $state<{ folderId: string; focusSearch: boolean } | null>(null);
let timer: ReturnType<typeof setTimeout> | undefined;

export function getFolderPeek(): { folderId: string; focusSearch: boolean } | null {
	return peek;
}

export function openFolderPeek(folderId: string, focusSearch: boolean): void {
	clearTimeout(timer);
	peek = { folderId, focusSearch };
}

export function closeFolderPeek(): void {
	clearTimeout(timer);
	peek = null;
}

// The pointer is on a folder's row or popover. A popover holding the focus keeps its place.
export function hoverFolderPeek(folderId: string): void {
	clearTimeout(timer);
	if (peek?.folderId === folderId || document.activeElement?.closest(".folder-popover")) return;
	timer = setTimeout(() => openFolderPeek(folderId, false), PEEK_DELAY_MS);
}

export function leaveFolderPeek(): void {
	clearTimeout(timer);
	if (!peek) return;
	timer = setTimeout(() => {
		if (!document.activeElement?.closest(".folder-popover")) peek = null;
	}, PEEK_LEAVE_GRACE_MS);
}
