import { on } from "../lib/bridge";
import type { BridgeDownloadSnapshot } from "../lib/bridge/protocol";
import { isActiveDownload } from "./downloads.svelte";

// The downloads that just started or ended, newest first, until their stack above the downloads button leaves.
let _stack = $state.raw<BridgeDownloadSnapshot[]>([]);
const STACK_LIMIT = 3;
// Whether each download seen was running at its last update.
const _running = new Map<number, boolean>();

// A download joins the stack as it starts and comes back to its front as it ends; progress updates it in place.
on("downloadUpdated", (dl) => {
	const running = isActiveDownload(dl);
	const surfaces = _running.get(dl.id) !== running;
	_running.set(dl.id, running);
	const stacked = _stack.findIndex((d) => d.id === dl.id);
	// A download the user canceled has nothing left to offer.
	if (dl.error === "USER_CANCELED") dismissDownloadStack(dl.id);
	else if (surfaces) _stack = [dl, ..._stack.filter((d) => d.id !== dl.id)].slice(0, STACK_LIMIT);
	else if (stacked >= 0) _stack = _stack.with(stacked, dl);
});

on("downloadErased", (data) => dismissDownloadStack(data.id));

export const getDownloadStack = (): BridgeDownloadSnapshot[] => _stack;

/** Takes one download off the stack, or all of them. */
export function dismissDownloadStack(id?: number): void {
	const next = id === undefined ? [] : _stack.filter((d) => d.id !== id);
	if (next.length !== _stack.length) _stack = next;
}
