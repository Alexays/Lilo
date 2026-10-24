// Lifecycle tests for the dndItem action under a minimal stub DOM (no jsdom in
// the toolchain): a manual rAF queue, a window stub that records listeners, and
// rect-only elements, following the store.test.ts fake-element pattern.
import assert from "node:assert/strict";
import test from "node:test";

type FrameCallback = () => void;
let nextFrameId = 1;
const frames = new Map<number, FrameCallback>();

function flushFrames(): void {
	const pending = [...frames.values()];
	frames.clear();
	for (const frame of pending) frame();
}

const windowListeners = new Map<string, Set<(event: unknown) => void>>();

function listenersFor(type: string): Set<(event: unknown) => void> {
	let set = windowListeners.get(type);
	if (!set) {
		set = new Set();
		windowListeners.set(type, set);
	}
	return set;
}

class FakeElement {}

const globals = globalThis as Record<string, unknown>;
globals.requestAnimationFrame = (fn: FrameCallback) => {
	const id = nextFrameId++;
	frames.set(id, fn);
	return id;
};
globals.cancelAnimationFrame = (id: number) => {
	frames.delete(id);
};
globals.Element = FakeElement;
// Nothing in the stub DOM scrolls, so auto-scroll always finds no container.
globals.getComputedStyle = () => ({ overflowY: "visible" });
globals.DOMRect = class {
	constructor(
		public x = 0,
		public y = 0,
		public width = 0,
		public height = 0,
	) {}
	get left() { return this.x; }
	get top() { return this.y; }
};
globals.window = {
	__liloBootstrapEvents: [],
	addEventListener: (type: string, fn: (event: unknown) => void) => {
		listenersFor(type).add(fn);
	},
	removeEventListener: (type: string, fn: (event: unknown) => void) => {
		listenersFor(type).delete(fn);
	},
	// Reduced motion keeps drop/cancel previews on the synchronous removal path.
	matchMedia: () => ({ matches: true }),
	innerWidth: 800,
	innerHeight: 600,
};

const previewRemovals: number[] = [];

function stubPreview(): Record<string, unknown> {
	return {
		id: "",
		classList: { add() {}, contains: () => false, toggle() {} },
		style: {},
		dataset: {},
		setAttribute() {},
		remove() {
			previewRemovals.push(1);
		},
		getBoundingClientRect: () => ({ left: 0, top: 0, width: 10, height: 10 }),
	};
}

const appendedPreviews: unknown[] = [];

globals.document = {
	body: {
		appendChild: (el: unknown) => {
			appendedPreviews.push(el);
		},
	},
	querySelector: () => null,
};

type StubNode = {
	dataset: Record<string, string>;
	isConnected: boolean;
	addEventListener: (type: string, fn: (event: unknown) => void) => void;
	removeEventListener: (type: string, fn: (event: unknown) => void) => void;
	getBoundingClientRect: () => { left: number; top: number; right: number; bottom: number; width: number; height: number };
	cloneNode: () => unknown;
	listeners: Map<string, Set<(event: unknown) => void>>;
};

function stubNode(rect: { left: number; top: number; width: number; height: number }): StubNode {
	const listeners = new Map<string, Set<(event: unknown) => void>>();
	return {
		dataset: {},
		// Keeps capturePointer/releasePointer on their early-return path.
		isConnected: false,
		listeners,
		addEventListener(type, fn) {
			let set = listeners.get(type);
			if (!set) {
				set = new Set();
				listeners.set(type, set);
			}
			set.add(fn);
		},
		removeEventListener(type, fn) {
			listeners.get(type)?.delete(fn);
		},
		getBoundingClientRect: () => ({
			left: rect.left,
			top: rect.top,
			right: rect.left + rect.width,
			bottom: rect.top + rect.height,
			width: rect.width,
			height: rect.height,
		}),
		cloneNode: () => stubPreview(),
	};
}

function elementRect(left: number, top: number, width: number, height: number) {
	return {
		getBoundingClientRect: () => ({
			left,
			top,
			right: left + width,
			bottom: top + height,
			width,
			height,
		}),
	} as unknown as HTMLElement;
}

const { dndItem } = await import("./action");
const { dndEngineStore } = await import("./store.svelte");

function pointerEvent(pointerId: number, x: number, y: number) {
	return { pointerId, button: 0, clientX: x, clientY: y, target: undefined };
}

function dispatchNode(node: StubNode, type: string, event: unknown): void {
	for (const fn of node.listeners.get(type) ?? []) fn(event);
}

function dispatchWindow(type: string, event: unknown): void {
	for (const fn of [...listenersFor(type)]) fn(event);
}

function resetStubs(): void {
	frames.clear();
	windowListeners.clear();
	previewRemovals.length = 0;
	appendedPreviews.length = 0;
}

test("dndItem dispatches onDragLeave to the departed zone on zone cross", () => {
	resetStubs();
	const leaves: string[] = [];
	const moves: string[] = [];
	dndEngineStore.registerZone(elementRect(0, 0, 240, 100), {
		id: "zone-a",
		axis: "vertical",
		getItems: () => [],
		onDragLeave: () => leaves.push("zone-a"),
	});
	dndEngineStore.registerZone(elementRect(0, 100, 240, 100), {
		id: "zone-b",
		axis: "vertical",
		getItems: () => [],
		onDragMove: (drag) => moves.push(drag.target?.zoneId ?? ""),
	});

	const node = stubNode({ left: 0, top: 0, width: 240, height: 20 });
	const action = dndItem(node as unknown as HTMLElement, {
		item: { id: "tab-a", kind: "tab" },
		zoneId: "zone-a",
	});

	dispatchNode(node, "pointerdown", pointerEvent(1, 10, 10));
	// Crosses the start threshold inside zone A, then moves into zone B.
	dispatchWindow("pointermove", pointerEvent(1, 10, 50));
	flushFrames();
	assert.equal(dndEngineStore.activeDrag?.target?.zoneId, "zone-a");

	dispatchWindow("pointermove", pointerEvent(1, 10, 150));
	flushFrames();
	assert.equal(dndEngineStore.activeDrag?.target?.zoneId, "zone-b");
	assert.deepEqual(leaves, ["zone-a"]);
	assert.deepEqual(moves, ["zone-b"]);

	dispatchWindow("pointerup", pointerEvent(1, 10, 150));
	action.destroy();
	dndEngineStore.unregisterZone("zone-a");
	dndEngineStore.unregisterZone("zone-b");
});

test("dndItem destroy() mid-drag keeps window listeners so pointerup can finish and clean up", () => {
	resetStubs();
	dndEngineStore.registerZone(elementRect(0, 0, 240, 100), {
		id: "zone-a",
		axis: "vertical",
		getItems: () => [],
	});

	const node = stubNode({ left: 0, top: 0, width: 240, height: 20 });
	const action = dndItem(node as unknown as HTMLElement, {
		item: { id: "tab-a", kind: "tab" },
		zoneId: "zone-a",
	});
	assert.equal(node.listeners.get("pointerdown")?.size, 1);

	dispatchNode(node, "pointerdown", pointerEvent(1, 10, 10));
	dispatchWindow("pointermove", pointerEvent(1, 10, 60));
	flushFrames();
	assert.equal(appendedPreviews.length, 1, "a started drag mounts a preview node");

	// Projection can unmount the source node mid-drag: the drag must survive it.
	action.destroy();
	assert.equal(node.listeners.get("pointerdown")?.size, 0);
	assert.equal(listenersFor("pointermove").size, 1);
	assert.equal(listenersFor("pointerup").size, 1);

	dispatchWindow("pointerup", pointerEvent(1, 10, 60));
	assert.equal(listenersFor("pointermove").size, 0);
	assert.equal(listenersFor("pointerup").size, 0);
	assert.equal(listenersFor("pointercancel").size, 0);
	assert.ok(previewRemovals.length >= 1, "the preview node is removed on drop");
	assert.equal(dndEngineStore.activeDrag, null);
	dndEngineStore.unregisterZone("zone-a");
});

test("dndItem cancels a started drag on Escape and drops its window listeners", () => {
	resetStubs();
	let cancelled = 0;
	dndEngineStore.registerZone(elementRect(0, 0, 240, 100), {
		id: "zone-a",
		axis: "vertical",
		getItems: () => [],
		onCancel: () => {
			cancelled += 1;
		},
	});

	const node = stubNode({ left: 0, top: 0, width: 240, height: 20 });
	const action = dndItem(node as unknown as HTMLElement, {
		item: { id: "tab-a", kind: "tab" },
		zoneId: "zone-a",
	});

	dispatchNode(node, "pointerdown", pointerEvent(1, 10, 10));
	dispatchWindow("pointermove", pointerEvent(1, 10, 60));
	flushFrames();
	assert.equal(dndEngineStore.activeDrag?.started, true);

	let consumed = 0;
	dispatchWindow("keydown", { key: "Escape", preventDefault: () => consumed++, stopPropagation: () => consumed++ });
	assert.equal(cancelled, 1);
	// The drag takes the Escape whole: no panel or bar around it closes as well.
	assert.equal(consumed, 2);
	assert.equal(dndEngineStore.activeDrag, null);
	assert.equal(listenersFor("pointermove").size, 0);
	assert.equal(listenersFor("keydown").size, 0);
	assert.ok(previewRemovals.length >= 1, "the preview node is removed on cancel");

	action.destroy();
	dndEngineStore.unregisterZone("zone-a");
});

test("dndItem destroy() outside a drag removes its listeners and pending frames", () => {
	resetStubs();
	const node = stubNode({ left: 0, top: 0, width: 240, height: 20 });
	const action = dndItem(node as unknown as HTMLElement, {
		item: { id: "tab-b", kind: "tab" },
		zoneId: "zone-a",
	});

	action.destroy();
	assert.equal(node.listeners.get("pointerdown")?.size, 0);
	assert.equal(frames.size, 0);
	assert.equal(dndEngineStore.itemElements.has("tab-b"), false);
});

test("dndItem hands a drop outside the window to onDropOutsideWindow instead of cancelling", () => {
	resetStubs();
	let cancelled = 0;
	const droppedOutside: { id: string; screenX: number; screenY: number }[] = [];
	dndEngineStore.registerZone(elementRect(0, 0, 240, 100), {
		id: "zone-a",
		axis: "vertical",
		getItems: () => [],
		onCancel: () => {
			cancelled += 1;
		},
	});
	const node = stubNode({ left: 0, top: 0, width: 240, height: 20 });
	const action = dndItem(node as unknown as HTMLElement, {
		item: { id: "tab-a", kind: "tab" },
		zoneId: "zone-a",
		onCancel: () => {
			cancelled += 1;
		},
		onDropOutsideWindow: (drag, point) => {
			droppedOutside.push({ id: drag.source.item.id, ...point });
		},
	});

	dispatchNode(node, "pointerdown", pointerEvent(1, 10, 10));
	dispatchWindow("pointermove", pointerEvent(1, 10, 60));
	flushFrames();
	dispatchWindow("pointerup", { ...pointerEvent(1, -40, 300), screenX: 1500, screenY: 420 });

	assert.deepEqual(droppedOutside, [{ id: "tab-a", screenX: 1500, screenY: 420 }]);
	assert.equal(cancelled, 0);
	assert.equal(dndEngineStore.activeDrag, null);

	action.destroy();
	dndEngineStore.unregisterZone("zone-a");
});

test("dndItem cancels a drag whose pointerup was lost once a buttonless move arrives", () => {
	resetStubs();
	let cancelled = 0;
	dndEngineStore.registerZone(elementRect(0, 0, 240, 100), { id: "zone-a", axis: "vertical", getItems: () => [] });
	const node = stubNode({ left: 0, top: 0, width: 240, height: 20 });
	const action = dndItem(node as unknown as HTMLElement, {
		item: { id: "tab-a", kind: "tab" },
		zoneId: "zone-a",
		onCancel: () => {
			cancelled += 1;
		},
	});

	dispatchNode(node, "pointerdown", pointerEvent(1, 10, 10));
	dispatchWindow("pointermove", pointerEvent(1, 10, 60));
	flushFrames();
	assert.equal(dndEngineStore.activeDrag?.started, true);

	dispatchWindow("pointermove", { ...pointerEvent(1, 10, 80), buttons: 0 });
	assert.equal(cancelled, 1);
	assert.equal(dndEngineStore.activeDrag, null);
	assert.equal(listenersFor("pointermove").size, 0);

	action.destroy();
	dndEngineStore.unregisterZone("zone-a");
});

test("dndItem ignores ctrl-click and cancels a live session before a new pointerdown", () => {
	resetStubs();
	let cancelled = 0;
	dndEngineStore.registerZone(elementRect(0, 0, 240, 100), { id: "zone-a", axis: "vertical", getItems: () => [] });
	const node = stubNode({ left: 0, top: 0, width: 240, height: 20 });
	const action = dndItem(node as unknown as HTMLElement, {
		item: { id: "tab-a", kind: "tab" },
		zoneId: "zone-a",
		onCancel: () => {
			cancelled += 1;
		},
	});

	dispatchNode(node, "pointerdown", { ...pointerEvent(1, 10, 10), ctrlKey: true });
	assert.equal(dndEngineStore.activeDrag === null, true);
	assert.equal(listenersFor("pointermove").size, 0);

	dispatchNode(node, "pointerdown", pointerEvent(1, 10, 10));
	dispatchWindow("pointermove", pointerEvent(1, 10, 60));
	flushFrames();
	dispatchNode(node, "pointerdown", pointerEvent(1, 10, 10));
	assert.equal(cancelled, 1, "the stale started drag is cancelled");
	assert.equal(dndEngineStore.activeDrag?.started, false);

	dispatchWindow("pointerup", pointerEvent(1, 10, 10));
	assert.equal(listenersFor("pointermove").size, 0);
	assert.equal(dndEngineStore.activeDrag, null);

	action.destroy();
	dndEngineStore.unregisterZone("zone-a");
});
