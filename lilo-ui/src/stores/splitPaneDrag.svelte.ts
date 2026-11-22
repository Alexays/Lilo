// A split pane being dragged by its handle: the native side tracks the gesture and
// reports it here, in the same content-area fractions the pane frames use.

import { tabActions } from "../lib/bridge/actions";
import { on } from "../lib/bridge";
import { paneMoveTarget } from "../lib/splitPaneMove";
import { getSplitPanes } from "./splitPanes.svelte";

export type SplitPaneDrag = { tabId: string; x: number; y: number };

let drag = $state.raw<SplitPaneDrag | null>(null);

export function initSplitPaneDragStore(): void {
	on("splitPaneDrag", ({ tabId, phase, x, y }) => {
		if (phase === "cancel") {
			drag = null;
			return;
		}
		const target = paneMoveTarget(getSplitPanes(), x, y, tabId);
		if (phase === "end") {
			drag = null;
			if (target) tabActions.splitTab(tabId, target.side, target.tabId);
			return;
		}
		drag = { tabId, x, y };
	});
}

/** Non-null while a pane is being moved. */
export function getSplitPaneDrag(): SplitPaneDrag | null {
	return drag;
}
