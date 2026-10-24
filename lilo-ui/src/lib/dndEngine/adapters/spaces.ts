import { MOTION } from "../../motion/timings";
import {
	DND_SHADOW_ITEM_ID_PREFIX,
	insertShadowItem,
	isShadowItem,
	removeShadowItems,
} from "../projection";
import type { DndItem } from "../types";

export type SpaceDndItem = DndItem & {
	kind: "space";
	isPrivate: boolean;
};

type SpaceLike = {
	id: string;
	isPrivate: boolean;
};

export function dndItemsForSpaces(spaces: SpaceLike[]): SpaceDndItem[] {
	return spaces.map((space) => ({
		id: space.id,
		kind: "space",
		isPrivate: space.isPrivate,
	}));
}

export function spaceDndKey(item: SpaceDndItem): string {
	return `${item.id}:${isShadowItem(item) ? "shadow" : "item"}`;
}

export function flipDurationForSpaceDndItem(item: SpaceDndItem): number {
	return isShadowItem(item) ? 0 : MOTION.reorderMs;
}

export function projectSpaceItemsWithShadow(
	items: readonly SpaceDndItem[],
	draggedId: string,
	targetIndex: number,
): SpaceDndItem[] {
	const dragged = items.find((item) => item.id === draggedId);
	if (!dragged || dragged.isPrivate) return [...items];

	const withoutDragged = removeShadowItems(items).filter((item) => item.id !== draggedId);
	return insertShadowItem(withoutDragged, dragged, targetIndex);
}

export function spaceMoveIndexFromProjectedItems({
	draggedId,
	previousItems,
	nextItems,
}: {
	draggedId: string;
	previousItems: SpaceDndItem[];
	nextItems: SpaceDndItem[];
}): number | null {
	const previousPersistentIndex = previousItems
		.filter((item) => !item.isPrivate && !isShadowItem(item))
		.findIndex((item) => item.id === draggedId);
	if (previousPersistentIndex < 0) return null;

	const insertionIndex = nextItems.findIndex((item) =>
		isShadowItem(item) && item.id === `${DND_SHADOW_ITEM_ID_PREFIX}${draggedId}`
	);
	if (insertionIndex < 0) return null;

	const nextPersistentIndex = nextItems
		.slice(0, insertionIndex)
		.filter((item) => !item.isPrivate && !isShadowItem(item) && item.id !== draggedId)
		.length;
	if (nextPersistentIndex === previousPersistentIndex) return null;

	return nextPersistentIndex;
}
