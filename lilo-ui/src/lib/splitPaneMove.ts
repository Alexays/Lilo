// Where a split pane dropped on another lands: on an edge it takes that half, on the
// center it swaps with the pane. Panes are the content-area fractions the native side reports.

import { MAX_SPLIT_PANES, type BridgeSplitPaneFrame, type SplitDropSide } from "./bridge/protocol";

export type PaneMoveTarget = { tabId: string; side: SplitDropSide };

// The pane's middle square: a drop there trades places instead of cutting.
const SWAP_EDGE = 0.25;

export function paneMoveTarget(
	panes: BridgeSplitPaneFrame[],
	x: number,
	y: number,
	draggedTabId: string,
): PaneMoveTarget | null {
	const pane = panes.find(
		(p) => x >= p.x && x <= p.x + p.width && y >= p.y && y <= p.y + p.height,
	);
	if (!pane || pane.tabId === draggedTabId) return null;
	// A full split has no edge left to cut: the pane itself is the target.
	if (panes.length >= MAX_SPLIT_PANES) return { tabId: pane.tabId, side: "replace" };
	const dx = (x - pane.x) / pane.width;
	const dy = (y - pane.y) / pane.height;
	if (dx >= SWAP_EDGE && dx <= 1 - SWAP_EDGE && dy >= SWAP_EDGE && dy <= 1 - SWAP_EDGE) {
		return { tabId: pane.tabId, side: "replace" };
	}
	const side =
		Math.min(dx, 1 - dx) <= Math.min(dy, 1 - dy)
			? dx < 0.5
				? "left"
				: "right"
			: dy < 0.5
				? "top"
				: "bottom";
	return { tabId: pane.tabId, side };
}
