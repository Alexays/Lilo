import type { DndItem } from "./types";

export const DND_SHADOW_ITEM_ID_PREFIX = "dnd-shadow:";

export function isShadowItem(item: Pick<DndItem, "id">): boolean {
	return item.id.startsWith(DND_SHADOW_ITEM_ID_PREFIX);
}

export function removeShadowItems<T extends DndItem>(items: readonly T[]): T[] {
	return items.filter((item) => !isShadowItem(item));
}

function clampIndex(index: number, length: number): number {
	if (!Number.isFinite(index)) return length;
	return Math.max(0, Math.min(Math.trunc(index), length));
}

export function insertShadowItem<T extends DndItem>(
	items: readonly T[],
	dragged: T,
	targetIndex: number,
): T[] {
	const cleaned = removeShadowItems(items);
	const insertionIndex = clampIndex(targetIndex, cleaned.length);
	const shadow = {
		...dragged,
		id: `${DND_SHADOW_ITEM_ID_PREFIX}${dragged.id}`,
	} as T;

	return [
		...cleaned.slice(0, insertionIndex),
		shadow,
		...cleaned.slice(insertionIndex),
	];
}
