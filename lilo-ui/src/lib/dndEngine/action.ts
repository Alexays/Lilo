import {
	dndEngineStore,
	type DndItemParams,
	type DndZoneParams,
} from "./store.svelte";
import type { DndItem } from "./types";
import { isPointInsideRect } from "./geometry";
import { on } from "../bridge";
import { createFrameScheduler } from "../motion/frameScheduler";
import { prefersReducedMotion } from "../motion/reducedMotion";

const DRAG_START_THRESHOLD_PX = 4;
const AUTO_SCROLL_EDGE_PX = 40;
const AUTO_SCROLL_MAX_STEP_PX = 16;

// Spring ease for Web Animations API previews. Mirrors the CSS `--motion-ease-spring`
// token (global.css); WAAPI easing must be a literal string, not a CSS var reference.
const SPRING_EASING = "cubic-bezier(0.22, 1, 0.36, 1)";
const DROP_LAND_MS = 300;
// Mirrors the `dnd-preview-lift` keyframes in global.css.
const LIFT_SCALE = 1.03;
const PREVIEW_EDGE_PX = 4;
// Mirrors `#dnd-action-dragged-el.dnd-preview-compact` in global.css.
const COMPACT_PREVIEW_PX = 156;

type DndActionReturn<Params> = {
	update: (params: Params) => void;
	destroy: () => void;
};

export function dndZone(
	node: HTMLElement,
	params: DndZoneParams,
): DndActionReturn<DndZoneParams> {
	let current = params;
	dndEngineStore.registerZone(node, current);

	return {
		update(next: DndZoneParams) {
			dndEngineStore.updateZone(node, current.id, next);
			current = next;
		},
		destroy() {
			dndEngineStore.unregisterZone(current.id);
		},
	};
}

export function dndItem(
	node: HTMLElement,
	params: DndItemParams,
): DndActionReturn<DndItemParams> {
	let current = params;
	let activePointerId: number | null = null;
	const pointerFrame = createFrameScheduler();
	const settleFrame = createFrameScheduler();
	const autoScrollFrame = createFrameScheduler();
	let autoScrollZone: HTMLElement | null = null;
	let autoScrollContainer: HTMLElement | null = null;
	let lastEvent: PointerEvent | null = null;
	let hasStarted = false;
	let didNotifyStart = false;
	let didCapturePointer = false;
	let lastNotifiedTargetZoneId: string | null = null;
	let lastNotifiedTargetIndex = -1;
	let previewElement: HTMLElement | null = null;
	let disposeWindowFocus: (() => void) | null = null;
	let disposeCancelDrag: (() => void) | null = null;

	node.dataset.dndItemId = current.item.id;
	dndEngineStore.registerItem(node, current);

	function pointerPoint(event: PointerEvent) {
		return {
			x: event.clientX,
			y: event.clientY,
		};
	}

	function movementFromStart(event: PointerEvent): number {
		const drag = dndEngineStore.activeDrag;
		if (!drag) return 0;
		return Math.hypot(
			event.clientX - drag.startPoint.x,
			event.clientY - drag.startPoint.y,
		);
	}

	function resolvePointerFrame(): void {
		if (!lastEvent) return;
		hasStarted = hasStarted || movementFromStart(lastEvent) >= DRAG_START_THRESHOLD_PX;
		const target = dndEngineStore.updatePointer(pointerPoint(lastEvent), hasStarted);
		const drag = dndEngineStore.activeDrag;
		if (!drag || !hasStarted) return;
		if (!previewElement) {
			previewElement = createDragPreview(node, drag.source.sourceRect, current.item, drag.startPoint);
		}
		updateDragPreview(previewElement, drag);
		setPreviewCompact(
			previewElement,
			!!drag.target && dndEngineStore.getZoneMeta(drag.target.zoneId)?.compactPreview === true,
		);
		autoScrollFrame.schedule(autoScroll);
		if (!didNotifyStart) {
			didNotifyStart = true;
			capturePointer(lastEvent);
			current.onDragStart?.(drag);
			dndEngineStore.invalidateLayoutSnapshot();
			if (drag.target) {
				lastNotifiedTargetZoneId = drag.target.zoneId;
				lastNotifiedTargetIndex = drag.target.index;
			}
			scheduleSettleResolve();
			return;
		}
		applyResolvedTarget(drag, target);
	}

	function scheduleSettleResolve(): void {
		settleFrame.schedule(() => {
			if (!lastEvent || !hasStarted) return;
			const target = dndEngineStore.updatePointer(pointerPoint(lastEvent), true);
			const drag = dndEngineStore.activeDrag;
			if (!drag) return;
			applyResolvedTarget(drag, target);
		});
	}

	function applyResolvedTarget(
		drag: NonNullable<typeof dndEngineStore.activeDrag>,
		target: ReturnType<typeof dndEngineStore.updatePointer>,
	): void {
		notifyTargetLeave(drag, target?.zoneId ?? null);
		if (!target) {
			lastNotifiedTargetZoneId = null;
			lastNotifiedTargetIndex = -1;
			return;
		}
		if (
			target.zoneId === lastNotifiedTargetZoneId &&
			target.index === lastNotifiedTargetIndex
		) {
			return;
		}
		lastNotifiedTargetZoneId = target.zoneId;
		lastNotifiedTargetIndex = target.index;
		notifyDragMove(drag);
		scheduleSettleResolve();
	}

	function notifyDragMove(drag: NonNullable<typeof dndEngineStore.activeDrag>): void {
		const targetCallbacks = targetZoneCallbacks(drag);
		if (targetCallbacks?.onDragMove) {
			targetCallbacks.onDragMove(drag);
		} else {
			current.onDragMove?.(drag);
		}
	}

	// Scrolls the list under the target zone while the pointer rests near its top or bottom
	// edge, faster the deeper it goes; each scroll re-resolves through handleScroll.
	function autoScroll(): void {
		const drag = dndEngineStore.activeDrag;
		if (!drag?.started) return;
		const zoneElement = dndEngineStore.zones.get(drag.target?.zoneId ?? drag.source.zoneId)?.element ?? null;
		if (zoneElement !== autoScrollZone) {
			autoScrollZone = zoneElement;
			autoScrollContainer = zoneElement ? scrollContainerOf(zoneElement) : null;
		}
		const container = autoScrollContainer;
		if (!container) return;
		const point = drag.currentPoint;
		const rect = container.getBoundingClientRect();
		if (!isPointInsideRect(point, rect)) return;
		const depth = point.y < rect.top + AUTO_SCROLL_EDGE_PX
			? point.y - rect.top - AUTO_SCROLL_EDGE_PX
			: Math.max(0, point.y - rect.bottom + AUTO_SCROLL_EDGE_PX);
		if (depth === 0) return;
		const before = container.scrollTop;
		container.scrollTop += Math.sign(depth) *
			Math.ceil(Math.min(1, Math.abs(depth) / AUTO_SCROLL_EDGE_PX) * AUTO_SCROLL_MAX_STEP_PX);
		if (container.scrollTop !== before) autoScrollFrame.schedule(autoScroll);
	}

	// A scroll, or a transition settling (the empty drop zones revealed at drag start),
	// moves rows under a pointer that may not move at all.
	function handleLayoutShift(): void {
		if (!hasStarted) return;
		dndEngineStore.invalidateLayoutSnapshot();
		pointerFrame.schedule(resolvePointerFrame);
	}

	function addWindowPointerListeners(): void {
		window.addEventListener("pointermove", handlePointerMove, true);
		window.addEventListener("pointerup", handlePointerUp, true);
		window.addEventListener("pointercancel", handlePointerCancel, true);
		window.addEventListener("keydown", handleKeyDown, true);
		window.addEventListener("scroll", handleLayoutShift, true);
		window.addEventListener("transitionend", handleLayoutShift, true);
		// The native window losing key is the only trustworthy "pointer is gone" signal
		// (a DOM blur also fires on the chrome-to-content first-responder handoff).
		disposeWindowFocus = on("windowFocusChanged", ({ focused }) => {
			if (!focused) cancelActiveDrag();
		});
		// Key focus usually stays on the page during a sidebar drag, so Escape reaches the native
		// side, which forwards it here.
		disposeCancelDrag = on("cancelDrag", () => cancelActiveDrag());
	}

	function removeWindowPointerListeners(): void {
		window.removeEventListener("pointermove", handlePointerMove, true);
		window.removeEventListener("pointerup", handlePointerUp, true);
		window.removeEventListener("pointercancel", handlePointerCancel, true);
		window.removeEventListener("keydown", handleKeyDown, true);
		window.removeEventListener("scroll", handleLayoutShift, true);
		window.removeEventListener("transitionend", handleLayoutShift, true);
		disposeWindowFocus?.();
		disposeWindowFocus = null;
		disposeCancelDrag?.();
		disposeCancelDrag = null;
	}

	function capturePointer(event: PointerEvent): void {
		if (didCapturePointer || !node.isConnected) return;
		try {
			node.setPointerCapture(event.pointerId);
			didCapturePointer = true;
		} catch {
			didCapturePointer = false;
		}
	}

	function releasePointer(): void {
		if (!didCapturePointer || !node.isConnected || activePointerId === null) return;
		try {
			node.releasePointerCapture(activePointerId);
		} catch {
			// Pointer capture may already be gone when projection removed the source node.
		}
		didCapturePointer = false;
	}

	function handlePointerDown(event: PointerEvent): void {
		if (current.disabled) return;
		// Ctrl-click opens the context menu on macOS, which swallows the matching pointerup.
		if (event.button !== 0 || event.ctrlKey) return;
		const nearestDraggable = event.target instanceof Element
			? event.target.closest<HTMLElement>("[data-dnd-item-id]")
			: null;
		if (nearestDraggable && nearestDraggable !== node) return;
		if (activePointerId !== null) cancelActiveDrag();

		activePointerId = event.pointerId;
		hasStarted = false;
		didNotifyStart = false;
		didCapturePointer = false;
		autoScrollZone = null;
		autoScrollContainer = null;
		lastNotifiedTargetZoneId = null;
		lastNotifiedTargetIndex = -1;
		destroyDragPreview();
		addWindowPointerListeners();
		dndEngineStore.startDrag({
			item: current.item,
			zoneId: current.zoneId,
			element: node,
			sourceRect: node.getBoundingClientRect(),
		}, pointerPoint(event));
	}

	function handlePointerMove(event: PointerEvent): void {
		if (activePointerId !== event.pointerId) return;
		// No button held: the pointerup was lost (e.g. to a context menu).
		if (event.buttons === 0) {
			cancelActiveDrag();
			return;
		}
		lastEvent = event;
		pointerFrame.schedule(resolvePointerFrame);
	}

	function handlePointerUp(event: PointerEvent): void {
		if (activePointerId !== event.pointerId) return;
		pointerFrame.cancel();
		settleFrame.cancel();
		autoScrollFrame.cancel();
		releasePointer();
		const previewDropRect = dndEngineStore.activeDrag?.started && previewElement
			? targetDropRect(dndEngineStore.activeDrag)
			: null;
		const drag = dndEngineStore.drop();
		const outsideWindow = event.clientX < 0 || event.clientY < 0
			|| event.clientX >= window.innerWidth || event.clientY >= window.innerHeight;
		if (drag?.started && outsideWindow && current.onDropOutsideWindow) {
			current.onDropOutsideWindow(drag, { screenX: event.screenX, screenY: event.screenY });
			removeWindowPointerListeners();
			destroyDragPreview();
			activePointerId = null;
			lastEvent = null;
			lastNotifiedTargetZoneId = null;
			lastNotifiedTargetIndex = -1;
			return;
		}
		if (drag?.started) {
			const targetCallbacks = targetZoneCallbacks(drag);
			if (targetCallbacks?.onDrop) {
				targetCallbacks.onDrop(drag);
			} else if (drag.target) {
				current.onDrop?.(drag);
			} else {
				current.onCancel?.(drag);
			}
		}
		removeWindowPointerListeners();
		if (drag?.started && previewElement) {
			if (previewDropRect) {
				animateDropPreview(previewElement, previewDropRect, drag.source.item.id);
			} else if (drag.target) {
				animateDropCompletePreview(previewElement);
			} else {
				animateSnapBackPreview(previewElement, drag);
			}
			previewElement = null;
		} else {
			destroyDragPreview();
		}
		activePointerId = null;
		lastEvent = null;
		lastNotifiedTargetZoneId = null;
		lastNotifiedTargetIndex = -1;
	}

	function handlePointerCancel(event: PointerEvent): void {
		if (activePointerId !== event.pointerId) return;
		cancelActiveDrag();
	}

	function handleKeyDown(event: KeyboardEvent): void {
		if (event.key !== "Escape" || activePointerId === null) return;
		// Escape during a drag cancels the drag only, never the panel or bar around it.
		event.preventDefault();
		event.stopPropagation();
		cancelActiveDrag();
	}

	function cancelActiveDrag(): void {
		pointerFrame.cancel();
		settleFrame.cancel();
		autoScrollFrame.cancel();
		releasePointer();
		const drag = dndEngineStore.cancelDrag();
		if (drag?.started) {
			const targetCallbacks = targetZoneCallbacks(drag);
			if (targetCallbacks?.onCancel) {
				targetCallbacks.onCancel(drag);
			} else {
				current.onCancel?.(drag);
			}
		}
		removeWindowPointerListeners();
		if (drag?.started && previewElement) {
			animateSnapBackPreview(previewElement, drag);
			previewElement = null;
		} else {
			destroyDragPreview();
		}
		activePointerId = null;
		lastEvent = null;
		lastNotifiedTargetZoneId = null;
		lastNotifiedTargetIndex = -1;
	}

	node.addEventListener("pointerdown", handlePointerDown);

	return {
		update(next: DndItemParams) {
			if (next.item.id === current.item.id) {
				current = next;
				node.dataset.dndItemId = current.item.id;
				return;
			}
			dndEngineStore.unregisterItem(current.item.id);
			current = next;
			node.dataset.dndItemId = current.item.id;
			dndEngineStore.registerItem(node, current);
		},
		destroy() {
			if (activePointerId === null) {
				pointerFrame.cancel();
				settleFrame.cancel();
				autoScrollFrame.cancel();
				destroyDragPreview();
				removeWindowPointerListeners();
			}
			dndEngineStore.unregisterItem(current.item.id);
			node.removeEventListener("pointerdown", handlePointerDown);
		},
	};

	function destroyDragPreview(): void {
		previewElement?.remove();
		previewElement = null;
	}

	function notifyTargetLeave(
		drag: NonNullable<typeof dndEngineStore.activeDrag>,
		nextZoneId: string | null,
	): void {
		if (!lastNotifiedTargetZoneId || lastNotifiedTargetZoneId === nextZoneId) return;
		const previousCallbacks = dndEngineStore.getZoneCallbacks(lastNotifiedTargetZoneId);
		previousCallbacks?.onDragLeave?.(drag);
	}
}

function targetZoneCallbacks(
	drag: NonNullable<typeof dndEngineStore.activeDrag>,
) {
	if (!drag.target) return null;
	return dndEngineStore.getZoneCallbacks(drag.target.zoneId);
}

function createDragPreview(node: HTMLElement, rect: DOMRect, item: DndItem, grab: { x: number; y: number }): HTMLElement {
	const preview = node.cloneNode(true) as HTMLElement;
	preview.id = "dnd-action-dragged-el";
	preview.classList.add(item.kind === "space" ? "space-dnd-preview" : "sidebar-dnd-preview");
	preview.style.position = "fixed";
	preview.style.left = `${rect.left}px`;
	preview.style.top = `${rect.top}px`;
	preview.style.width = `${rect.width}px`;
	preview.style.height = `${rect.height}px`;
	preview.style.margin = "0";
	preview.style.pointerEvents = "none";
	preview.style.zIndex = "10000";
	preview.style.transform = "translate3d(0px, 0px, 0)";
	preview.style.transition = "none";
	preview.style.willChange = "transform";
	preview.style.opacity = "0.92";
	preview.style.contain = "layout style paint";
	preview.style.backfaceVisibility = "hidden";
	preview.dataset.dndDragPreview = "true";
	preview.setAttribute("aria-hidden", "true");
	// The CSS lift scales around the grab point, like an object picked up between the fingers.
	preview.style.transformOrigin = `${grab.x - rect.left}px ${grab.y - rect.top}px`;
	document.body.appendChild(preview);
	return preview;
}

function updateDragPreview(preview: HTMLElement, drag: NonNullable<typeof dndEngineStore.activeDrag>): void {
	// Kept inside the window: a pane grabbed by its middle and aimed at the left edge of the
	// split row would otherwise slide half off-screen.
	const { left, width } = drag.source.sourceRect;
	const minX = PREVIEW_EDGE_PX - left;
	const maxX = window.innerWidth - PREVIEW_EDGE_PX - left - width;
	const deltaX = Math.min(Math.max(drag.currentPoint.x - drag.startPoint.x, minX), Math.max(minX, maxX));
	const deltaY = drag.currentPoint.y - drag.startPoint.y;
	preview.style.transform = `translate3d(${deltaX}px, ${deltaY}px, 0)`;
}

function setPreviewCompact(preview: HTMLElement, compact: boolean): void {
	if (preview.classList.contains("dnd-preview-compact") === compact) return;
	const from = preview.getBoundingClientRect().width;
	preview.classList.toggle("dnd-preview-compact", compact);
	if (prefersReducedMotion()) return;
	const to = compact ? COMPACT_PREVIEW_PX : parseFloat(preview.style.width) || from;
	preview.animate([{ maxWidth: `${from}px` }, { maxWidth: `${to}px` }], {
		duration: 160,
		easing: SPRING_EASING,
	});
}

// The preview flies opaque to the slot, then hands over to the landed row in place: fading it out
// mid-flight would show its text doubled over the row already rendered there.
function animateDropPreview(
	preview: HTMLElement,
	targetRect: DOMRect,
	itemId: string,
): void {
	if (prefersReducedMotion()) {
		preview.remove();
		return;
	}
	// Resized rather than scaled: a scaled clone squeezes its own padding and icon. Started on the
	// next frame, once the settled row exists, so the clone's tab content (which keeps its source
	// indent) lands exactly on the row's own content and the hand-over shows no doubled text.
	const originLeft = parseFloat(preview.style.left) || 0;
	const originTop = parseFloat(preview.style.top) || 0;
	const baseTransform = preview.style.transform || "translate3d(0px, 0px, 0)";
	requestAnimationFrame(() => {
		const row = document.querySelector<HTMLElement>(
			`[data-dnd-item-id="${CSS.escape(itemId)}"]:not([data-is-dnd-shadow-item-hint="true"])`,
		);
		const target = { left: targetRect.left, top: targetRect.top, width: targetRect.width, height: targetRect.height };
		const rowContent = row?.querySelector<HTMLElement>("[data-tab-id]");
		const previewContent = preview.querySelector<HTMLElement>("[data-tab-id]");
		if (row && rowContent && previewContent) {
			// Offsets inside each box are transform-invariant, so a row still FLIP-ing is fine.
			const r = row.getBoundingClientRect();
			const rc = rowContent.getBoundingClientRect();
			const p = preview.getBoundingClientRect();
			const pc = previewContent.getBoundingClientRect();
			target.left += (rc.left - r.left) - (pc.left - p.left);
			target.top += (rc.top - r.top) - (pc.top - p.top);
			target.width += (p.width - pc.width) - (r.width - rc.width);
			target.height += (p.height - pc.height) - (r.height - rc.height);
		}
		const landed = `translate3d(${target.left - originLeft}px, ${target.top - originTop}px, 0)`;
		const from = { transform: baseTransform, width: preview.style.width, height: preview.style.height, scale: String(LIFT_SCALE) };
		const to = { transform: landed, width: `${target.width}px`, height: `${target.height}px`, scale: "1", rotate: "0deg" };
		const animation = preview.animate([
			{ ...from, opacity: 0.92, offset: 0, easing: bounceEasing() },
			{ ...to, opacity: 0.92, offset: 0.72, easing: "linear" },
			{ ...to, opacity: 0, offset: 1 },
		], {
			duration: DROP_LAND_MS,
			fill: "forwards",
		});
		row?.animate([
			{ opacity: 0, offset: 0 },
			{ opacity: 0, offset: 0.68 },
			{ opacity: 1, offset: 1 },
		], { duration: DROP_LAND_MS });
		removePreviewWhenFinished(animation, preview);
	});
}

// The spring token from global.css, for the Web Animations API (which takes no CSS variables).
function bounceEasing(): string {
	return getComputedStyle(document.documentElement).getPropertyValue("--motion-ease-bounce").trim() || SPRING_EASING;
}

function animateSnapBackPreview(
	preview: HTMLElement,
	drag: NonNullable<typeof dndEngineStore.activeDrag>,
): void {
	if (prefersReducedMotion()) {
		preview.remove();
		return;
	}
	const previewRect = preview.getBoundingClientRect();
	const sourceRect = drag.source.sourceRect;
	const deltaX = sourceRect.left - previewRect.left;
	const deltaY = sourceRect.top - previewRect.top;
	const scaleX = sourceRect.width > 0 ? sourceRect.width / Math.max(previewRect.width, 1) : 1;
	const scaleY = sourceRect.height > 0 ? sourceRect.height / Math.max(previewRect.height, 1) : 1;
	const baseTransform = preview.style.transform || "translate3d(0px, 0px, 0)";
	const animation = preview.animate([
		{ transform: baseTransform, scale: String(LIFT_SCALE), opacity: 0.92 },
		{
			transform: `${baseTransform} translate3d(${deltaX}px, ${deltaY}px, 0) scale(${scaleX}, ${scaleY})`,
			scale: "1",
			opacity: 1,
		},
	], {
		duration: 320,
		easing: bounceEasing(),
		fill: "forwards",
	});
	removePreviewWhenFinished(animation, preview);
}

function animateDropCompletePreview(preview: HTMLElement): void {
	if (prefersReducedMotion()) {
		preview.remove();
		return;
	}
	const baseTransform = preview.style.transform || "translate3d(0px, 0px, 0)";
	const animation = preview.animate([
		{ transform: baseTransform, scale: String(LIFT_SCALE), opacity: 0.92 },
		{ transform: baseTransform, scale: "0.96", opacity: 0 },
	], {
		duration: 160,
		easing: "cubic-bezier(0.16, 0.84, 0.32, 1)",
		fill: "forwards",
	});
	removePreviewWhenFinished(animation, preview);
}

function removePreviewWhenFinished(animation: Animation, preview: HTMLElement): void {
	void animation.finished
		.catch(() => undefined)
		.finally(() => preview.remove());
}

function targetDropRect(
	drag: NonNullable<typeof dndEngineStore.activeDrag>,
): DOMRect | null {
	const shadow = document.querySelector<HTMLElement>(
		`[data-dnd-item-id="dnd-shadow:${drag.source.item.id}"]`,
	);
	if (shadow) return shadow.getBoundingClientRect();
	// No placeholder (a tab dropped onto a space icon): land on the item under the pointer.
	if (!drag.target) return null;
	const item = dndEngineStore.getZoneSnapshot(drag.target.zoneId)?.items
		.find((candidate) => isPointInsideRect(drag.currentPoint, candidate.rect));
	return item ? new DOMRect(item.rect.left, item.rect.top, item.rect.width, item.rect.height) : null;
}

function scrollContainerOf(element: HTMLElement): HTMLElement | null {
	for (let node: HTMLElement | null = element; node; node = node.parentElement) {
		const overflowY = getComputedStyle(node).overflowY;
		if ((overflowY === "auto" || overflowY === "scroll") && node.scrollHeight > node.clientHeight) {
			return node;
		}
	}
	return null;
}
