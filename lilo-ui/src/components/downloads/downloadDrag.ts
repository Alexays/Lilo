import type { ActionReturn } from "svelte/action";
import { downloadActions } from "../../lib/bridge/actions";

interface DownloadDrag {
	/** The finished download whose file the node drags out, or null when there is no file to drag. */
	id: number | null;
	onstart?: () => void;
}

const CLICK_SLOP = 4;

/** Hands the file to a native drag once a press on the node moves; a plain click still clicks. */
export function downloadDrag(node: HTMLElement, options: DownloadDrag): ActionReturn<DownloadDrag> {
	let press: { x: number; y: number } | null = null;
	let dragged = false;

	const start = () => {
		if (!press || options.id === null) return;
		press = null;
		dragged = true;
		downloadActions.startDrag(options.id);
		options.onstart?.();
	};
	const handleDown = (event: PointerEvent) => {
		dragged = false;
		press = event.button === 0 && options.id !== null ? { x: event.clientX, y: event.clientY } : null;
	};
	const handleMove = (event: PointerEvent) => {
		if (press && Math.hypot(event.clientX - press.x, event.clientY - press.y) >= CLICK_SLOP) start();
	};
	const handleUp = () => {
		press = null;
	};
	// Only reached when the native drag did not take the release with it.
	const handleClick = (event: MouseEvent) => {
		if (!dragged) return;
		dragged = false;
		event.preventDefault();
		event.stopImmediatePropagation();
	};

	node.addEventListener("pointerdown", handleDown);
	node.addEventListener("pointermove", handleMove);
	node.addEventListener("pointerleave", start);
	node.addEventListener("pointerup", handleUp);
	node.addEventListener("pointercancel", handleUp);
	node.addEventListener("click", handleClick, true);
	return {
		update(next) {
			options = next;
		},
		destroy() {
			node.removeEventListener("pointerdown", handleDown);
			node.removeEventListener("pointermove", handleMove);
			node.removeEventListener("pointerleave", start);
			node.removeEventListener("pointerup", handleUp);
			node.removeEventListener("pointercancel", handleUp);
			node.removeEventListener("click", handleClick, true);
		},
	};
}
