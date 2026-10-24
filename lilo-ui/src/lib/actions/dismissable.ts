import type { Attachment } from "svelte/attachments";
import { on } from "../bridge";

type DismissableOptions = {
	onDismiss: () => void;
	// Presses inside these, besides the node itself, keep it open: the toggle that opened it
	// would otherwise reopen it on the same click.
	ignore?: string;
	escape?: boolean;
	// Takes focus back when a press outside closes the node while it held focus and lands on
	// nothing that takes focus.
	returnFocus?: HTMLElement;
};

/** Dismisses on a press outside the node, a click in the page, and optionally Escape. */
export function dismissable({ onDismiss, ignore, escape, returnFocus }: DismissableOptions): Attachment<HTMLElement> {
	return (node) => {
		const handlePointerDown = (event: PointerEvent) => {
			const target = event.target as Element | null;
			if (target && (node.contains(target) || (ignore && target.closest(ignore)))) return;
			const heldFocus = node.contains(document.activeElement);
			onDismiss();
			// The press moves focus after this handler: check once it has.
			if (returnFocus && heldFocus) {
				setTimeout(() => {
					if (!document.activeElement || document.activeElement === document.body) returnFocus.focus();
				});
			}
		};
		const handleKeydown = (event: KeyboardEvent) => {
			// An Escape the focused bar already took (leaving a scope, closing the find bar) is not ours.
			if (event.key !== "Escape" || event.defaultPrevented) return;
			event.preventDefault();
			onDismiss();
		};
		const disposeContentInteraction = on("contentInteraction", (event) => {
			if (event.isMouseDown) onDismiss();
		});
		window.addEventListener("pointerdown", handlePointerDown, true);
		if (escape) window.addEventListener("keydown", handleKeydown);
		return () => {
			disposeContentInteraction();
			window.removeEventListener("pointerdown", handlePointerDown, true);
			window.removeEventListener("keydown", handleKeydown);
		};
	};
}
