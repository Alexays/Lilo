import type {
	DndAxis,
	DndItem,
	DndItemRect,
	DndPoint,
	DndRect,
	DndResolvedTarget,
	DndTargetContext,
	DndZoneMeta,
	DndZoneSnapshot,
} from "./types";
import { applyTargetHysteresis, isPointInsideRect, resolveTargetFromPoint } from "./geometry";
import { isShadowItem } from "./projection";

export type DndZoneParams = {
	id: string;
	axis: DndAxis;
	meta?: DndZoneMeta;
	getItems?: () => DndItem[];
	canResolve?: (context: DndTargetContext) => boolean;
	// Some zones accept a drop onto a row without accepting insertion between rows.
	resolveOnItem?: (context: DndTargetContext) => string | undefined;
	onDragMove?: DndItemDragCallback;
	onDragLeave?: DndItemDragCallback;
	onDrop?: DndItemDragCallback;
	onCancel?: DndItemDragCallback;
};

export type DndItemParams = {
	item: DndItem;
	zoneId: string;
	disabled?: boolean;
	onDragStart?: DndItemDragCallback;
	onDragMove?: DndItemDragCallback;
	onDrop?: DndItemDragCallback;
	onCancel?: DndItemDragCallback;
	// A drop released outside the window, at a screen point (CSS px, origin top-left of the main screen).
	onDropOutsideWindow?: (drag: DndActiveDrag, point: { screenX: number; screenY: number }) => void;
};

type DndDragSource = {
	item: DndItem;
	zoneId: string;
	element: HTMLElement;
};

export type DndActiveDrag = {
	source: DndDragSource;
	home?: number;
	startPoint: DndPoint;
	currentPoint: DndPoint;
	target: DndResolvedTarget | null;
	started: boolean;
};

type DndItemDragCallback = (drag: DndActiveDrag) => void;

type DndZoneRegistration = DndZoneParams & {
	element: HTMLElement;
};

// How far outside its zone the pointer may stray (section margins, the pinned divider)
// before the last target is released.
const GAP_HOLD_PX = 16;

export class DndEngineStore {
	zones = new Map<string, DndZoneRegistration>();
	itemElements = new Map<string, HTMLElement>();
	private drag: DndActiveDrag | null = null;
	private layoutSnapshot: DndZoneSnapshot[] | null = null;
	private layoutSnapshotStale = true;
	private layoutMeasureCount = 0;
	// Scroll offset of each container that scrolled during the drag, as of the cached layout.
	private scrollOffsets = new Map<Element, DndPoint>();
	private listeners = new Set<() => void>();
	private lastNotifiedActive = false;
	private lastNotifiedSourceId = "";
	private lastNotifiedZoneId = "";
	private lastNotifiedIndex = -1;
	private lastNotifiedOnItemId: string | undefined;

	get activeDrag(): DndActiveDrag | null {
		return this.drag;
	}

	/** Layout measurement passes performed so far (test observability). */
	get measureCount(): number {
		return this.layoutMeasureCount;
	}

	// Observers are notified when the drag *outcome* changes (start, resolved target,
	// end), not on every pointer frame, so mirroring this into reactive state does
	// not re-render the sidebar 60 times a second.
	subscribe(listener: () => void): () => void {
		this.listeners.add(listener);
		return () => {
			this.listeners.delete(listener);
		};
	}

	private notifyIfChanged(): void {
		const drag = this.drag;
		// A press that never crosses the drag threshold is a plain click: observers never hear of it.
		const active = drag?.started === true;
		const sourceId = active ? drag.source.item.id : "";
		const zoneId = drag?.target?.zoneId ?? "";
		const index = drag?.target?.index ?? -1;
		const onItemId = drag?.target?.onItemId;
		if (
			active === this.lastNotifiedActive &&
			sourceId === this.lastNotifiedSourceId &&
			zoneId === this.lastNotifiedZoneId &&
			index === this.lastNotifiedIndex &&
			onItemId === this.lastNotifiedOnItemId
		) {
			return;
		}
		this.lastNotifiedActive = active;
		this.lastNotifiedSourceId = sourceId;
		this.lastNotifiedZoneId = zoneId;
		this.lastNotifiedIndex = index;
		this.lastNotifiedOnItemId = onItemId;
		for (const listener of this.listeners) listener();
	}

	registerZone(element: HTMLElement, params: DndZoneParams): void {
		this.zones.set(params.id, { ...params, element });
		this.invalidateLayoutSnapshot();
	}

	updateZone(element: HTMLElement, previousId: string, params: DndZoneParams): void {
		if (previousId !== params.id || !this.zones.has(previousId)) {
			this.zones.delete(previousId);
			this.zones.set(params.id, { ...params, element });
			this.invalidateLayoutSnapshot();
			return;
		}
		const wasCollapsed = this.zones.get(previousId)?.meta?.isCollapsed;
		this.zones.set(params.id, { ...params, element });
		// A folder opening under the drag changes where the drop lands, though the target stays the same.
		if (this.drag?.started && wasCollapsed !== params.meta?.isCollapsed) {
			this.invalidateLayoutSnapshot();
			for (const listener of this.listeners) listener();
		}
	}

	unregisterZone(id: string): void {
		this.zones.delete(id);
		this.invalidateLayoutSnapshot();
	}

	registerItem(element: HTMLElement, params: DndItemParams): void {
		this.itemElements.set(params.item.id, element);
		if (!isShadowItem(params.item)) {
			this.invalidateLayoutSnapshot();
		}
	}

	// An item moving between zones mounts its new node before the old one is torn down: the old
	// node must not take the new one's entry with it, or the zone measures as empty.
	unregisterItem(id: string, element: HTMLElement): void {
		if (this.itemElements.get(id) !== element) return;
		this.itemElements.delete(id);
		if (!isShadowItem({ id })) {
			this.invalidateLayoutSnapshot();
		}
	}

	// Every pointerdown on a row lands here, so nothing is measured or notified until the
	// drag actually starts.
	startDrag(source: DndDragSource, startPoint: DndPoint): void {
		this.layoutSnapshot = null;
		this.layoutSnapshotStale = true;
		this.scrollOffsets.clear();
		this.drag = {
			source,
			home: this.zones.get(source.zoneId)?.getItems?.().findIndex((item) => item.id === source.item.id),
			startPoint,
			currentPoint: startPoint,
			target: null,
			started: false,
		};
		this.notifyIfChanged();
	}

	updatePointer(point: DndPoint, started: boolean): DndResolvedTarget | null {
		const drag = this.drag;
		if (!drag) return null;
		drag.currentPoint = point;
		drag.started = drag.started || started;
		if (!drag.started) return null;
		const previous = drag.target;
		drag.target = this.resolveTarget(point);
		// A new target reprojects the placeholder and reflows every row after it, so the
		// next resolve has to measure the layout the user now sees.
		if (drag.target?.zoneId !== previous?.zoneId || drag.target?.index !== previous?.index) {
			this.layoutSnapshotStale = true;
		}
		this.notifyIfChanged();
		return drag.target;
	}

	drop(): DndActiveDrag | null {
		return this.endDrag();
	}

	cancelDrag(): DndActiveDrag | null {
		return this.endDrag();
	}

	private endDrag(): DndActiveDrag | null {
		const drag = this.drag;
		this.drag = null;
		this.layoutSnapshot = null;
		this.layoutSnapshotStale = true;
		this.scrollOffsets.clear();
		// Observers must not see the drag end until pointerup dispatch is over, or a listener torn down on "drag ended"
		// misses a drop onto the space bar. A microtask is too early (checkpoints run between listeners).
		setTimeout(() => this.notifyIfChanged(), 0);
		return drag;
	}

	invalidateLayoutSnapshot(): void {
		this.layoutSnapshotStale = true;
	}

	// Everything inside a scrolled container moves by the scroll delta, so the cached rects follow it
	// unmeasured. Zones and items are never sticky inside their scroller, or they would not move with it.
	followScroll(container: Element): void {
		const previous = this.scrollOffsets.get(container);
		const offset = { x: container.scrollLeft, y: container.scrollTop };
		this.scrollOffsets.set(container, offset);
		if (!previous || !this.layoutSnapshot || this.layoutSnapshotStale) {
			this.layoutSnapshotStale = true;
			return;
		}
		const dx = previous.x - offset.x;
		const dy = previous.y - offset.y;
		if (dx === 0 && dy === 0) return;
		for (const zone of this.layoutSnapshot) {
			const element = this.zones.get(zone.id)?.element;
			if (element && element !== container && container.contains(element)) zone.rect = shiftRect(zone.rect, dx, dy);
			for (const item of zone.items) {
				const itemElement = this.itemElements.get(item.id);
				if (itemElement && container.contains(itemElement)) item.rect = shiftRect(item.rect, dx, dy);
			}
		}
	}

	getZoneSnapshot(zoneId: string): DndZoneSnapshot | null {
		if (this.drag) {
			return this.ensureLayoutSnapshot().find((zone) => zone.id === zoneId) ?? null;
		}

		const zone = this.zones.get(zoneId);
		if (!zone) return null;

		return this.snapshotForZone(zone);
	}

	getZoneMeta(zoneId: string): DndZoneMeta | null {
		return this.zones.get(zoneId)?.meta ?? null;
	}

	getZoneCallbacks(zoneId: string): Pick<DndZoneParams, "onDragMove" | "onDragLeave" | "onDrop" | "onCancel"> | null {
		return this.zones.get(zoneId) ?? null;
	}

	private resolveTarget(point: DndPoint): DndResolvedTarget | null {
		const drag = this.drag;
		if (!drag) return null;
		const zones = this.ensureLayoutSnapshot();
		// Neighbour space panes stay mounted (hidden) over the page area, so a zone
		// only resolves for a drag that started in the same space.
		const sourceSpaceId = this.zones.get(drag.source.zoneId)?.meta?.spaceId;
		let resolvedTarget: DndResolvedTarget | null = null;
		let resolvedZone: DndZoneSnapshot | null = null;
		let insideAnyZone = false;

		for (const snapshot of zones) {
			const zone = this.zones.get(snapshot.id);
			if (!zone) continue;
			const zoneSpaceId = zone.meta?.spaceId;
			if (
				sourceSpaceId !== undefined &&
				zoneSpaceId !== undefined &&
				zoneSpaceId !== sourceSpaceId
			) {
				continue;
			}
			if (!isPointInsideRect(point, snapshot.rect)) continue;
			insideAnyZone = true;
			const context = { point, zone: snapshot, dragSource: drag.source.item };
			const onItemId = zone.resolveOnItem?.(context);
			if (!onItemId && zone.canResolve && !zone.canResolve(context)) {
				continue;
			}
			const target = onItemId
				? { zoneId: snapshot.id, axis: snapshot.axis, onItemId }
				: resolveTargetFromPoint(point, snapshot);
			if (target && (!resolvedZone || rectArea(snapshot.rect) < rectArea(resolvedZone.rect))) {
				resolvedTarget = target;
				resolvedZone = snapshot;
			}
		}

		if (!resolvedTarget || !resolvedZone) {
			// Only true gaps hold: a point inside a zone that refused it is a real "no target".
			const previous = drag.target;
			if (insideAnyZone || !previous || previous.onItemId) return null;
			const previousZone = zones.find((zone) => zone.id === previous.zoneId);
			if (!previousZone || !isPointInsideRect(point, previousZone.rect, GAP_HOLD_PX)) return null;
			return { ...previous, zoneRect: previousZone.rect };
		}
		const target = applyTargetHysteresis(
			point,
			resolvedZone,
			resolvedTarget,
			drag.target,
		);
		return target ? { ...target, zoneRect: resolvedZone.rect } : null;
	}

	private ensureLayoutSnapshot(): DndZoneSnapshot[] {
		if (!this.layoutSnapshot || this.layoutSnapshotStale) {
			return this.captureLayoutSnapshot();
		}
		return this.layoutSnapshot;
	}

	private captureLayoutSnapshot(): DndZoneSnapshot[] {
		this.layoutMeasureCount += 1;
		const offsets = rowAnimationOffsets();
		this.layoutSnapshot = Array.from(this.zones.values()).map((zone) => this.snapshotForZone(zone, offsets));
		this.layoutSnapshotStale = false;
		// The new rects hold the current scroll offsets: a scroll event still on its way must not shift them again.
		for (const container of this.scrollOffsets.keys()) {
			this.scrollOffsets.set(container, { x: container.scrollLeft, y: container.scrollTop });
		}
		return this.layoutSnapshot;
	}

	private snapshotForZone(zone: DndZoneRegistration, offsets: AnimationOffsets = null): DndZoneSnapshot {
		// Indices address the list with the dragged row lifted out, which is how it is
		// projected; its own slot is still in the DOM until the first projection lands.
		const draggedId = this.drag?.source.item.id;
		const items: DndItemRect[] = [];
		for (const item of zone.getItems?.() ?? []) {
			if (isShadowItem(item) || item.id === draggedId) continue;
			const element = this.itemElements.get(item.id);
			if (element) items.push({ id: item.id, rect: settledRect(element, offsets) });
		}
		return {
			id: zone.id,
			axis: zone.axis,
			rect: settledRect(zone.element, offsets),
			items,
			home: zone.id === this.drag?.source.zoneId ? this.drag.home : undefined,
		};
	}
}

type AnimationOffsets = Map<Element, DndPoint> | null;

// Rows slide to their new slot (FLIP) right after a reprojection, which is exactly when the
// layout is re-measured. Hit testing needs the slot, so in-flight row translations are taken out.
function rowAnimationOffsets(): AnimationOffsets {
	const animations = globalThis.document?.getAnimations?.();
	if (!animations?.length) return null;
	let offsets: AnimationOffsets = null;
	for (const animation of animations) {
		const target = (animation.effect as KeyframeEffect | null)?.target;
		if (!(target instanceof HTMLElement) || target.dataset.dndItemId === undefined) continue;
		if (offsets?.has(target)) continue;
		const transform = getComputedStyle(target).transform;
		if (transform === "none") continue;
		const matrix = new DOMMatrixReadOnly(transform);
		if (matrix.m41 === 0 && matrix.m42 === 0) continue;
		(offsets ??= new Map()).set(target, { x: matrix.m41, y: matrix.m42 });
	}
	return offsets;
}

function settledRect(element: HTMLElement, offsets: AnimationOffsets): DndRect {
	const rect = element.getBoundingClientRect();
	let dx = 0;
	let dy = 0;
	if (offsets) {
		for (let node: Element | null = element; node; node = node.parentElement) {
			const offset = offsets.get(node);
			if (!offset) continue;
			dx += offset.x;
			dy += offset.y;
		}
	}
	return {
		left: rect.left - dx,
		top: rect.top - dy,
		right: rect.right - dx,
		bottom: rect.bottom - dy,
		width: rect.width,
		height: rect.height,
	};
}

function shiftRect(rect: DndRect, dx: number, dy: number): DndRect {
	return {
		left: rect.left + dx,
		top: rect.top + dy,
		right: rect.right + dx,
		bottom: rect.bottom + dy,
		width: rect.width,
		height: rect.height,
	};
}

function rectArea(rect: DndRect): number {
	return rect.width * rect.height;
}

export const dndEngineStore = new DndEngineStore();
