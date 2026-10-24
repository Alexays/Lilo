import type {
	DndItemRect,
	DndPoint,
	DndRect,
	DndResolvedTarget,
	DndZoneSnapshot,
} from "./types";

export type { DndZoneSnapshot } from "./types";

export function isPointInsideRect(point: DndPoint, rect: DndRect, margin = 0): boolean {
	return point.x >= rect.left - margin &&
		point.x <= rect.right + margin &&
		point.y >= rect.top - margin &&
		point.y <= rect.bottom + margin;
}

function rectCenter(rect: DndRect): DndPoint {
	return {
		x: rect.left + rect.width / 2,
		y: rect.top + rect.height / 2,
	};
}

function resolveLinearTarget(
	point: DndPoint,
	zone: DndZoneSnapshot,
): DndResolvedTarget {
	const coordinate = axisCoordinate(point, zone.axis);

	for (let index = 0; index < zone.items.length; index += 1) {
		if (coordinate < itemMidpoint(zone.items[index], zone.axis)) {
			return { zoneId: zone.id, index, axis: zone.axis };
		}
	}

	return { zoneId: zone.id, index: zone.items.length, axis: zone.axis };
}

function resolveGridTarget(
	point: DndPoint,
	zone: DndZoneSnapshot,
): DndResolvedTarget {
	const rows: { startIndex: number; items: DndItemRect[] }[] = [];
	let placedCount = 0;
	for (const item of zone.items) {
		const lastRow = rows.at(-1);
		if (
			lastRow &&
			Math.abs(item.rect.top - lastRow.items[0].rect.top) < item.rect.height / 2
		) {
			lastRow.items.push(item);
		} else {
			// startIndex = items already placed in earlier rows, tracked incrementally so
			// this stays O(n) instead of re-summing every prior row.
			rows.push({ startIndex: placedCount, items: [item] });
		}
		placedCount += 1;
	}

	// Below the last occupied row (still inside the zone) is the trailing slot. The snapshot
	// leaves out the dragged tile's placeholder, so when it sits alone on a new last row that row
	// is missing here; snapping to the nearest row instead flips the target every frame.
	if (point.y > rows[rows.length - 1].items[0].rect.bottom) {
		return { zoneId: zone.id, index: zone.items.length, axis: "grid" };
	}

	const row = rows.find((candidate) =>
		point.y >= candidate.items[0].rect.top &&
		point.y <= candidate.items[0].rect.bottom
	) ?? rows.reduce((best, candidate) => {
		const bestDistance = Math.abs(point.y - rectCenter(best.items[0].rect).y);
		const candidateDistance = Math.abs(point.y - rectCenter(candidate.items[0].rect).y);
		return candidateDistance < bestDistance ? candidate : best;
	}, rows[0]);

	for (let offset = 0; offset < row.items.length; offset += 1) {
		if (point.x < rectCenter(row.items[offset].rect).x) {
			return { zoneId: zone.id, index: row.startIndex + offset, axis: "grid" };
		}
	}

	return { zoneId: zone.id, index: row.startIndex + row.items.length, axis: "grid" };
}

function axisCoordinate(point: DndPoint, axis: DndZoneSnapshot["axis"]): number {
	return axis === "horizontal" ? point.x : point.y;
}

function itemMidpoint(item: DndItemRect, axis: DndZoneSnapshot["axis"]): number {
	return axis === "horizontal"
		? item.rect.left + item.rect.width / 2
		: item.rect.top + item.rect.height / 2;
}

export function applyTargetHysteresis(
	point: DndPoint,
	zone: DndZoneSnapshot,
	next: DndResolvedTarget | null,
	previous: DndResolvedTarget | null,
	margin = 6,
): DndResolvedTarget | null {
	if (!next || !previous) return next;
	if (zone.axis === "grid") return next;
	if (next.zoneId !== previous.zoneId) return next;
	if (next.index === previous.index) return next;
	if (Math.abs(next.index - previous.index) > 1) return next;

	const boundaryItem = zone.items[Math.min(next.index, previous.index)];
	if (!boundaryItem) return next;

	const coordinate = axisCoordinate(point, zone.axis);
	const boundary = itemMidpoint(boundaryItem, zone.axis);
	if (next.index > previous.index && coordinate < boundary + margin) {
		return previous;
	}
	if (next.index < previous.index && coordinate > boundary - margin) {
		return previous;
	}
	return next;
}

export function resolveTargetFromPoint(
	point: DndPoint,
	zone: DndZoneSnapshot,
): DndResolvedTarget | null {
	if (!isPointInsideRect(point, zone.rect)) return null;

	if (zone.items.length === 0) {
		return { zoneId: zone.id, index: 0, axis: zone.axis };
	}

	if (zone.axis === "grid") {
		return resolveGridTarget(point, zone);
	}

	return resolveLinearTarget(point, zone);
}
