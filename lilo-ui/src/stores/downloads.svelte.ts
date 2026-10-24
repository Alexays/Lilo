import { on } from "../lib/bridge";
import { downloadActions } from "../lib/bridge/actions";
import type { BridgeDownloadSnapshot } from "../lib/bridge/protocol";
import { announce } from "../lib/announce";
import { t } from "../lib/i18n/state.svelte";

// Downloads the chrome indicators care about (active or failed), newest first. Progress
// ticks land here several times a second: one write, and no re-sort, since startedAt never
// changes on an update.
let _downloads = $state.raw<BridgeDownloadSnapshot[]>([]);
// Whether anything downloaded since launch, and which of those ended unseen (id to failed).
let _sessionHasDownloads = $state(false);
let _unseen = $state.raw<Map<number, boolean>>(new Map());
const _announcedEnd = new Map<number, boolean>();

export function initDownloadsStore(): void {
	on("downloadsSnapshot", (data) => {
		_downloads = data.items
			.filter((dl) => dl.state !== "complete" || !!dl.error)
			.sort((a, b) => b.startedAt - a.startedAt);
	});
	on("downloadUpdated", (dl) => {
		_sessionHasDownloads = true;
		if (!isActiveDownload(dl)) {
			const failed = dl.state === "interrupted" || !!dl.error;
			if (_unseen.get(dl.id) !== failed) _unseen = new Map(_unseen).set(dl.id, failed);
			// Spoken once as it ends, never on progress ticks.
			if (_announcedEnd.get(dl.id) !== failed) {
				_announcedEnd.set(dl.id, failed);
				announce(t(failed ? "downloadsPanel.announceFailed" : "downloadsPanel.announceDone", { filename: dl.filename }));
			}
		}
		const idx = _downloads.findIndex((d) => d.id === dl.id);
		if (dl.state === "complete" && !dl.error) {
			if (idx >= 0) _downloads = _downloads.filter((d) => d.id !== dl.id);
			return;
		}
		_downloads =
			idx >= 0
				? _downloads.with(idx, dl)
				: [dl, ..._downloads].sort((a, b) => b.startedAt - a.startedAt);
	});
	on("downloadErased", (data) => {
		_downloads = _downloads.filter((d) => d.id !== data.id);
	});
	// Paused or failed downloads from a previous launch only exist in the snapshot.
	downloadActions.requestSnapshot();
}

export function getDownloads(): BridgeDownloadSnapshot[] {
	return _downloads;
}

export const hasSessionDownloads = (): boolean => _sessionHasDownloads;

/** How the downloads that ended since they were last looked at went, or null when none did. */
export function getUnseenDownloads(): "failed" | "done" | null {
	if (_unseen.size === 0) return null;
	return [..._unseen.values()].some(Boolean) ? "failed" : "done";
}

export function markDownloadsSeen(): void {
	// Braced so the Svelte compiler keeps esbuild's /* @__PURE__ */ on `new Map()`.
	if (_unseen.size > 0) {
		_unseen = new Map();
	}
}

export function isActiveDownload(dl: BridgeDownloadSnapshot): boolean {
	return dl.state === "inProgress" || dl.state === "paused";
}

/** Received fraction (0 to 1) across the given downloads of known size, or -1 when none has one. */
export function aggregateDownloadProgress(downloads: BridgeDownloadSnapshot[]): number {
	let received = 0;
	let total = 0;
	for (const dl of downloads) {
		if (dl.totalBytes <= 0) continue;
		received += dl.bytesReceived;
		total += dl.totalBytes;
	}
	return total > 0 ? Math.min(1, received / total) : -1;
}
