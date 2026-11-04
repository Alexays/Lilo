import { on } from "../lib/bridge";
import { downloadActions } from "../lib/bridge/actions";
import type { BridgeDownloadSnapshot } from "../lib/bridge/protocol";

// Every download the Downloads screen lists, newest first, and its search. The chrome's indicators keep
// their own shorter list in downloads.svelte.ts.
let _downloads = $state.raw<BridgeDownloadSnapshot[]>([]);
let _loaded = $state(false);
let _query = $state("");
let _listening = false;

export const getPageDownloads = (): BridgeDownloadSnapshot[] => _downloads;
export const arePageDownloadsLoaded = (): boolean => _loaded;
export const getDownloadsQuery = (): string => _query;

export function setDownloadsQuery(query: string): void {
	_query = query;
}

const isFinished = (dl: BridgeDownloadSnapshot): boolean => dl.state === "complete" || dl.state === "interrupted";

export const hasFinishedDownloads = (): boolean => _downloads.some(isFinished);

/** Asks for a fresh list; listens from the first open on, since the screen mounts with it. */
export function loadPageDownloads(): void {
	if (!_listening) {
		_listening = true;
		on("downloadsSnapshot", (data) => {
			_downloads = [...data.items].sort((a, b) => b.startedAt - a.startedAt);
			_loaded = true;
		});
		on("downloadUpdated", (data) => {
			const idx = _downloads.findIndex((d) => d.id === data.id);
			// One write, no re-sort: a progress tick never changes startedAt, so order is invariant.
			_downloads = idx >= 0 ? _downloads.with(idx, data) : [data, ..._downloads];
		});
		on("downloadErased", (data) => {
			_downloads = _downloads.filter((d) => d.id !== data.id);
		});
	}
	_query = "";
	downloadActions.requestSnapshot();
}

export function eraseDownload(dl: BridgeDownloadSnapshot): void {
	downloadActions.erase(dl.id);
	_downloads = _downloads.filter((d) => d.id !== dl.id);
}

export function clearFinishedDownloads(): void {
	for (const dl of _downloads) if (isFinished(dl)) downloadActions.erase(dl.id);
	_downloads = _downloads.filter((d) => !isFinished(d));
}
