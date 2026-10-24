type DropConfirmation<T> = {
	pending: (T & { createdAt: number }) | null;
};

type DropConfirmationStore<T> = {
	queuePending: (item: T) => void;
	clearPending: () => void;
	getPending: () => (T & { createdAt: number }) | null;
};

function createDropConfirmation<T>(): DropConfirmationStore<T> {
	const state: DropConfirmation<T> = $state({
		pending: null,
	});

	let pendingTimeout: ReturnType<typeof setTimeout> | null = null;

	function queuePending(item: T): void {
		if (pendingTimeout !== null) {
			clearTimeout(pendingTimeout);
		}
		state.pending = {
			...item,
			createdAt: Date.now(),
		};
		// Safety fallback: clear pending if Swift never confirms within 1.5s.
		pendingTimeout = setTimeout(() => {
			state.pending = null;
			pendingTimeout = null;
		}, 1500);
	}

	function clearPending(): void {
		if (!state.pending) {
			return;
		}

		if (pendingTimeout !== null) {
			clearTimeout(pendingTimeout);
			pendingTimeout = null;
		}
		state.pending = null;
	}

	function getPending(): (T & { createdAt: number }) | null {
		return state.pending;
	}

	return {
		queuePending,
		clearPending,
		getPending,
	};
}

// --- Tab drop confirmation ---

type TabDropItem = {
	tabId: string;
	kind: "move-space";
	targetSpaceId?: string;
};

// The host never confirms a tab move explicitly: the pending drop hides the tab from its source
// space until the move lands, and the fallback timeout ends it.
const tabDrop = createDropConfirmation<TabDropItem>();

export const queuePendingTabDrop = tabDrop.queuePending;
export const getPendingTabDrop = tabDrop.getPending;

type TabMoveSpacePreview = {
	tabId: string;
	targetSpaceId: string;
} | null;

let tabMoveSpacePreview = $state<TabMoveSpacePreview>(null);

export function setPreviewTabMoveToSpace(
	tabId: string,
	targetSpaceId: string,
): void {
	tabMoveSpacePreview = { tabId, targetSpaceId };
}

export function clearPreviewTabMoveToSpace(tabId?: string): void {
	if (tabId && tabMoveSpacePreview?.tabId !== tabId) return;
	tabMoveSpacePreview = null;
}

export function getPreviewTabMoveToSpace(): TabMoveSpacePreview {
	return tabMoveSpacePreview;
}

// --- Space drop confirmation ---

type ReorderableSpaceLike = {
	id: string;
	isPrivate?: boolean;
};

type SpaceDropItem = {
	spaceId: string;
	orderSignature: string;
};

function reorderSignature(spaces: ReorderableSpaceLike[]): string {
	return spaces
		.filter((space) => !space.isPrivate)
		.map((space) => space.id)
		.join("|");
}

const spaceDrop = createDropConfirmation<SpaceDropItem>();

let recentlyDroppedSpaceId = $state<string | null>(null);
let recentDropTimeout: ReturnType<typeof setTimeout> | null = null;

export function isSpaceRecentlyDropped(spaceId: string): boolean {
	return recentlyDroppedSpaceId === spaceId;
}

function markSpaceRecentDrop(spaceId: string): void {
	recentlyDroppedSpaceId = spaceId;
	if (recentDropTimeout !== null) clearTimeout(recentDropTimeout);
	recentDropTimeout = setTimeout(() => {
		recentlyDroppedSpaceId = null;
		recentDropTimeout = null;
	}, 900);
}

export function queuePendingSpaceDrop(
	spaceId: string,
	spaces: ReorderableSpaceLike[],
): void {
	spaceDrop.queuePending({
		spaceId,
		orderSignature: reorderSignature(spaces),
	});
}

export function resolvePendingSpaceDrop(
	spaces: ReorderableSpaceLike[],
): boolean {
	const pending = spaceDrop.getPending();
	if (!pending) {
		return false;
	}

	const nextSignature = reorderSignature(spaces);
	if (nextSignature === pending.orderSignature) {
		return false;
	}

	if (!spaces.some((space) => !space.isPrivate && space.id === pending.spaceId)) {
		spaceDrop.clearPending();
		return false;
	}

	spaceDrop.clearPending();
	markSpaceRecentDrop(pending.spaceId);
	return true;
}
