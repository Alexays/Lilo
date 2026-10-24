// Where each pane of the visible split sits, as the native side lays them out.

import { on } from "../lib/bridge";
import type { BridgeSplitPaneFrame } from "../lib/bridge/protocol";

// Raw: each update swaps the whole list.
let splitPanes = $state.raw<BridgeSplitPaneFrame[]>([]);

export function initSplitPanesStore(): void {
	on("splitPanesChanged", ({ panes }) => {
		splitPanes = panes;
	});
}

/** Empty when no split is on screen. */
export function getSplitPanes(): BridgeSplitPaneFrame[] {
	return splitPanes;
}
