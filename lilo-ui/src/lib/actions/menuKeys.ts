import type { Attachment } from "svelte/attachments";

/** Up and Down walk a menu's enabled items, wrapping around; Home and End jump to the first and last. */
export const menuKeys: Attachment<HTMLElement> = (node) => {
	const handleKeydown = (event: KeyboardEvent) => {
		const { key } = event;
		if (key !== "ArrowDown" && key !== "ArrowUp" && key !== "Home" && key !== "End") return;
		// A field in the menu keeps its own caret keys.
		if (event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement) return;
		const items = Array.from(node.querySelectorAll<HTMLElement>("[role^='menuitem']:not(:disabled)"));
		if (items.length === 0) return;
		event.preventDefault();
		const index = items.indexOf(document.activeElement as HTMLElement);
		const next =
			key === "Home" || (key === "ArrowDown" && index < 0) ? 0
			: key === "End" || index < 0 ? items.length - 1
			: (index + (key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
		items[next].focus();
	};
	node.addEventListener("keydown", handleKeydown);
	return () => node.removeEventListener("keydown", handleKeydown);
};
