import { chromeActions } from "../bridge/actions";
import type { BridgeCommandPayloadMap } from "../bridge/protocol";
import { createFrameScheduler } from "../motion/frameScheduler";

type InteractiveZoneConfig = {
	id: string;
	active?: boolean;
};

type InteractiveZoneEntry = {
	el: HTMLElement;
	zoneId: string;
	active: boolean;
	lastRect: { x: number; y: number; width: number; height: number } | null;
};

const GEOMETRY_TRANSITION_PROPS = new Set([
	"transform",
	"left",
	"right",
	"top",
	"bottom",
	"width",
	"height",
]);

function isGeometryTransition(propertyName: string): boolean {
	return (
		GEOMETRY_TRANSITION_PROPS.has(propertyName) ||
		propertyName.startsWith("inset")
	);
}

const entriesByElement = new Map<Element, InteractiveZoneEntry>();
const pendingEntries = new Set<InteractiveZoneEntry>();
const flushFrame = createFrameScheduler();

// Missed transition/animation end events (element unmounted mid-transition) would
// otherwise keep the geometry poll alive forever.
const POLL_IDLE_FRAME_CAP = 90;

let resizeObserver: ResizeObserver | null = null;
let globalListenersInstalled = false;

type ZoneRect = BridgeCommandPayloadMap["registerInteractiveZones"]["zones"][number];

function reportEntry(entry: InteractiveZoneEntry, batch: ZoneRect[]): void {
	if (!entry.active) {
		if (entry.lastRect !== null) {
			chromeActions.removeInteractiveZone(entry.zoneId);
			entry.lastRect = null;
		}
		return;
	}

	const rect = entry.el.getBoundingClientRect();
	if (rect.width <= 0 || rect.height <= 0) {
		if (entry.lastRect !== null) {
			chromeActions.removeInteractiveZone(entry.zoneId);
			entry.lastRect = null;
		}
		return;
	}

	const { x, y, width, height } = rect;
	const last = entry.lastRect;
	if (last && last.x === x && last.y === y && last.width === width && last.height === height) {
		return;
	}

	entry.lastRect = { x, y, width, height };
	batch.push({ id: entry.zoneId, x, y, width, height });
}

// One bridge message per frame: a window or sidebar resize moves every zone at once.
function flushPendingEntries(): void {
	const zones: ZoneRect[] = [];
	for (const entry of pendingEntries) {
		reportEntry(entry, zones);
	}

	pendingEntries.clear();
	if (zones.length !== 0) {
		chromeActions.registerInteractiveZones(zones);
	}
}

function scheduleEntry(entry: InteractiveZoneEntry): void {
	pendingEntries.add(entry);
	flushFrame.schedule(flushPendingEntries);
}

function scheduleAllEntries(): void {
	for (const entry of entriesByElement.values()) {
		if (!entry.active) {
			continue;
		}
		pendingEntries.add(entry);
	}

	if (pendingEntries.size === 0) {
		return;
	}

	flushFrame.schedule(flushPendingEntries);
}

function installGlobalObservers(): void {
	if (resizeObserver === null) {
		resizeObserver = new ResizeObserver((entries) => {
			for (const { target } of entries) {
				const entry = entriesByElement.get(target);
				if (entry?.active) {
					scheduleEntry(entry);
				}
			}
		});
	}

	if (globalListenersInstalled) {
		return;
	}

	// No scroll listener: every zone sits in the fixed sidebar overlay, so inner scrolls never move their rects.
	window.addEventListener("resize", scheduleAllEntries);
	globalListenersInstalled = true;
}

function uninstallGlobalObserversIfIdle(): void {
	if (entriesByElement.size !== 0) {
		return;
	}

	flushFrame.cancel();
	pendingEntries.clear();

	if (globalListenersInstalled) {
		window.removeEventListener("resize", scheduleAllEntries);
		globalListenersInstalled = false;
	}

	resizeObserver?.disconnect();
	resizeObserver = null;
}

export function reportInteractiveZone(
	el: HTMLElement,
	config: InteractiveZoneConfig,
) {
	installGlobalObservers();

	const entry: InteractiveZoneEntry = {
		el,
		zoneId: config.id,
		active: config.active ?? true,
		lastRect: null,
	};

	let pollingFrame = 0;
	let activeAnimations = 0;
	let activeTransitions = 0;

	const stopPolling = () => {
		if (pollingFrame !== 0) {
			cancelAnimationFrame(pollingFrame);
			pollingFrame = 0;
		}
	};

	const startPolling = () => {
		if (pollingFrame !== 0) return;
		let idleFrames = 0;
		let lastSeenRect = entry.lastRect;
		const tick = () => {
			scheduleEntry(entry);
			// reportEntry replaces entry.lastRect only when the rect moved, so a
			// stable reference across many frames means the poll can stop even if
			// the matching transition/animation end event never arrives.
			if (entry.lastRect === lastSeenRect) {
				idleFrames += 1;
				if (idleFrames >= POLL_IDLE_FRAME_CAP) {
					pollingFrame = 0;
					activeAnimations = 0;
					activeTransitions = 0;
					return;
				}
			} else {
				idleFrames = 0;
				lastSeenRect = entry.lastRect;
			}
			pollingFrame = requestAnimationFrame(tick);
		};
		pollingFrame = requestAnimationFrame(tick);
	};

	const isOwnMotionEvent = (event: Event) => event.target === el;

	const handleTransitionStart = (event: TransitionEvent) => {
		if (!isOwnMotionEvent(event) || !isGeometryTransition(event.propertyName)) return;
		activeTransitions++;
		startPolling();
	};
	const handleTransitionEnd = (event: TransitionEvent) => {
		if (!isOwnMotionEvent(event) || !isGeometryTransition(event.propertyName)) return;
		activeTransitions = Math.max(0, activeTransitions - 1);
		stopPollingIfIdle();
	};
	const handleAnimationStart = (event: Event) => {
		if (!isOwnMotionEvent(event)) return;
		activeAnimations++;
		startPolling();
	};
	const handleAnimationEnd = (event: Event) => {
		if (!isOwnMotionEvent(event)) return;
		activeAnimations = Math.max(0, activeAnimations - 1);
		stopPollingIfIdle();
	};
	const stopPollingIfIdle = () => {
		if (activeTransitions === 0 && activeAnimations === 0) {
			stopPolling();
			scheduleEntry(entry);
		}
	};

	entriesByElement.set(el, entry);
	resizeObserver?.observe(el);
	el.addEventListener("transitionstart", handleTransitionStart);
	el.addEventListener("transitionend", handleTransitionEnd);
	el.addEventListener("transitioncancel", handleTransitionEnd);
	el.addEventListener("animationstart", handleAnimationStart);
	el.addEventListener("animationend", handleAnimationEnd);
	el.addEventListener("animationcancel", handleAnimationEnd);
	scheduleEntry(entry);
	// Svelte's transitions run on the Web Animations API, which fires no animation or transition events: a card flying
	// in would keep the zone of its first, off-screen frame. Its intro has started by the next frame.
	requestAnimationFrame(() => {
		if (entriesByElement.get(el) === entry && el.getAnimations().length > 0) startPolling();
	});

	return {
		update(nextConfig: InteractiveZoneConfig) {
			const nextZoneId = nextConfig.id;
			const nextActive = nextConfig.active ?? true;

			if (entry.zoneId === nextZoneId && entry.active === nextActive) {
				return;
			}

			if (entry.lastRect !== null) {
				chromeActions.removeInteractiveZone(entry.zoneId);
				entry.lastRect = null;
			}
			entry.zoneId = nextZoneId;
			entry.active = nextActive;
			scheduleEntry(entry);
		},
		destroy() {
			stopPolling();
			activeAnimations = 0;
			activeTransitions = 0;
			pendingEntries.delete(entry);
			entriesByElement.delete(el);
			resizeObserver?.unobserve(el);
			el.removeEventListener("transitionstart", handleTransitionStart);
			el.removeEventListener("transitionend", handleTransitionEnd);
			el.removeEventListener("transitioncancel", handleTransitionEnd);
			el.removeEventListener("animationstart", handleAnimationStart);
			el.removeEventListener("animationend", handleAnimationEnd);
			el.removeEventListener("animationcancel", handleAnimationEnd);
			if (entry.lastRect !== null) {
				chromeActions.removeInteractiveZone(entry.zoneId);
			}
			uninstallGlobalObserversIfIdle();
		},
	};
}
