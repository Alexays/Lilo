// Latches the banner events Swift sends right after initialState, before the lazily mounted
// banners exist to subscribe: the bridge has no replay, so a critical store holds them.

import { on } from "../lib/bridge";
import { extensionActions } from "../lib/bridge/actions";

// Sequence, not a flag: each crash event bumps it so the banner restarts its auto-hide timer.
let _crashRecoverySeq = $state(0);
let _degradedSpaceName = $state<string | null>(null);
let _contentPlaceholderTabId = $state<string | null>(null);
let _contentPlaceholderLockedFolderId = $state<string | null>(null);
let _extensionDebuggers = $state.raw<{ id: string; name: string }[]>([]);

export function initBannersStore(): void {
	on("crashRecoveryDetected", () => {
		_crashRecoverySeq += 1;
	});
	on("sessionRestoreDegraded", (data) => {
		_degradedSpaceName = data.spaceName;
	});
	on("contentPlaceholder", (data) => {
		_contentPlaceholderTabId = data.tabId || null;
		_contentPlaceholderLockedFolderId = data.lockedFolderId || null;
	});
	on("extensionDebuggers", (data) => {
		_extensionDebuggers = data.debuggers;
	});
	extensionActions.loadDebuggers();
}

export function getCrashRecoverySeq(): number {
	return _crashRecoverySeq;
}

export function dismissCrashRecoveryBanner(): void {
	_crashRecoverySeq = 0;
}

export function getDegradedSpaceName(): string | null {
	return _degradedSpaceName;
}

export function dismissSessionRestoreDegradedBanner(): void {
	_degradedSpaceName = null;
}

export function getContentPlaceholderTabId(): string | null {
	return _contentPlaceholderTabId;
}

export function getContentPlaceholderLockedFolderId(): string | null {
	return _contentPlaceholderLockedFolderId;
}

/** Extensions debugging a tab now, each shown until it detaches. */
export function getExtensionDebuggers(): { id: string; name: string }[] {
	return _extensionDebuggers;
}
