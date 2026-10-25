import { on } from "./bridge";
import { areTrafficLightsVisible } from "../stores/ui.svelte";

type TooltipPlacement = "top" | "right" | "left" | "bottom";

type TooltipParams = string | {
	text: string;
	subtitle?: string;
	memory?: string;
	iconSrc?: string;
	iconText?: string;
	shortcut?: string;
	delay?: number;
	placement?: TooltipPlacement;
	disabled?: boolean;
	// Selector of an ancestor to position against instead of the node itself.
	anchor?: string;
};

let injected = false;

const DEFAULT_DELAY_MS = 400;
// Once a tip hides, the next one within this window shows at once: scanning a row of icons
// reads like macOS instead of waiting on each one.
const WARM_WINDOW_MS = 600;
let warmUntil = 0;
type TooltipController = {
	cancelAndHide: () => void;
};

const tooltipControllers = new Set<TooltipController>();

// Behaviors each mounted tooltip exposes to the shared window/document listeners below.
type TooltipGlobalHandlers = {
	leave: () => void;
	suppressForDrag: () => void;
};
const tooltipGlobalHandlers = new Set<TooltipGlobalHandlers>();
let globalTooltipListenersInstalled = false;

function isSidebarDragActive(): boolean {
	return document.body.className.includes("sidebar-dnd-active") ||
		document.documentElement.className.includes("sidebar-dnd-active");
}

// One shared set of window/document listeners fanning out to every mounted tooltip; registering
// them per instance doesn't scale (300+ tabs = 300+ identical listeners), mirroring hoverClear.ts.
function ensureGlobalTooltipListeners(): void {
	if (globalTooltipListenersInstalled) return;
	globalTooltipListenersInstalled = true;
	window.addEventListener("blur", () => {
		for (const handlers of tooltipGlobalHandlers) handlers.leave();
	});
	// A native context menu takes the mouse without a mouseleave or a window blur.
	document.addEventListener("contextmenu", () => {
		for (const handlers of tooltipGlobalHandlers) handlers.leave();
	}, true);
	document.addEventListener("visibilitychange", () => {
		if (document.visibilityState === "visible") return;
		for (const handlers of tooltipGlobalHandlers) handlers.leave();
	});
	document.addEventListener("lilo-sidebar-dnd-active-change", () => {
		if (!isSidebarDragActive()) return;
		for (const handlers of tooltipGlobalHandlers) handlers.suppressForDrag();
	});
	on("sidebarVisibilityChanged", ({ visible }) => {
		if (visible) return;
		for (const handlers of tooltipGlobalHandlers) handlers.leave();
	});
}

function topSafeInset(margin: number): number {
	if (!areTrafficLightsVisible()) return margin;
	const header = document.querySelector(".sidebar-header");
	if (header instanceof HTMLElement) {
		return Math.max(margin, header.getBoundingClientRect().bottom + 4);
	}
	// No header in the DOM (e.g. standalone surfaces): still clear the OS traffic
	// lights, which live in the top-left ~52px of the window.
	return Math.max(margin, 52);
}

function dismissOtherTooltips(current: TooltipController) {
	for (const controller of tooltipControllers) {
		if (controller !== current) {
			controller.cancelAndHide();
		}
	}
}

function inject() {
	if (injected) return;
	injected = true;
	const s = document.createElement("style");
	s.textContent = `
.lilo-tooltip {
  position: fixed;
  z-index: var(--z-tip);
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding: 4px 8px;
  border-radius: var(--float-radius-tip);
  background: var(--float-surface);
  box-shadow: var(--float-shadow);
  color: var(--float-text);
  font-size: 11.5px;
  font-weight: 500;
  font-family: inherit;
  line-height: 1.35;
  pointer-events: none;
  max-width: 280px;
  transform: translateX(-50%) translateY(calc(-100% - 6px));
  animation: lilo-tt-in 120ms cubic-bezier(.22,1,.36,1) both;
}
.lilo-tooltip.lilo-tooltip-rich {
  padding: 6px 9px;
}
.lilo-tooltip.lilo-tooltip-right {
  transform: translateY(-50%);
  animation-name: lilo-tt-right-in;
}
.lilo-tooltip.lilo-tooltip-left {
  transform: translateX(-100%) translateY(-50%);
  animation-name: lilo-tt-left-in;
}
.lilo-tooltip.lilo-tooltip-bottom {
  transform: translateX(-50%) translateY(6px);
  animation-name: lilo-tt-bottom-in;
}
.lilo-tooltip.lilo-tooltip-instant {
  animation: none;
}
.lilo-tooltip-row {
  display: flex;
  align-items: center;
  gap: 7px;
}
.lilo-tooltip-icon {
  width: 14px;
  height: 14px;
  border-radius: 3px;
  object-fit: cover;
  flex-shrink: 0;
}
.lilo-tooltip-text-icon {
  width: 14px;
  height: 14px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  font-size: 12px;
  line-height: 1;
}
.lilo-tooltip-title {
  white-space: normal;
  word-break: break-word;
  overflow-wrap: anywhere;
}
.lilo-tooltip-rich .lilo-tooltip-title {
  font-size: 12px;
  font-weight: 600;
}
.lilo-tooltip-shortcut {
  flex-shrink: 0;
  margin-left: 2px;
  padding: 0 5px;
  border-radius: 4px;
  background: var(--float-hover);
  color: var(--float-text-muted);
  font-size: 10.5px;
  line-height: 16px;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.lilo-tooltip-meta {
  display: flex;
  gap: 4px;
  min-width: 0;
  color: var(--float-text-muted);
  font-size: 11px;
  font-weight: 400;
  white-space: nowrap;
}
.lilo-tooltip-icon + .lilo-tooltip-title, .lilo-tooltip-text-icon + .lilo-tooltip-title {
  min-width: 0;
}
.lilo-tooltip-row:has(.lilo-tooltip-icon, .lilo-tooltip-text-icon) + .lilo-tooltip-meta {
  padding-left: 21px;
}
.lilo-tooltip-subtitle {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
}
.lilo-tooltip-memory {
  flex-shrink: 0;
  font-variant-numeric: tabular-nums;
}
.lilo-tooltip-subtitle + .lilo-tooltip-memory::before {
  content: "\\00B7  ";
}
.lilo-tooltip.lilo-tooltip-leaving {
  animation: lilo-tt-out 100ms cubic-bezier(.4,0,.2,1) forwards;
}
.lilo-tooltip.lilo-tooltip-right.lilo-tooltip-leaving {
  animation-name: lilo-tt-right-out;
}
.lilo-tooltip.lilo-tooltip-left.lilo-tooltip-leaving {
  animation-name: lilo-tt-left-out;
}
.lilo-tooltip.lilo-tooltip-bottom.lilo-tooltip-leaving {
  animation-name: lilo-tt-bottom-out;
}
@keyframes lilo-tt-in {
  from { opacity:0; transform:translateX(-50%) translateY(calc(-100% - 3px)); }
}
@keyframes lilo-tt-right-in {
  from { opacity:0; transform:translateY(-50%) translateX(-3px); }
}
@keyframes lilo-tt-left-in {
  from { opacity:0; transform:translateX(-100%) translateY(-50%) translateX(3px); }
}
@keyframes lilo-tt-bottom-in {
  from { opacity:0; transform:translateX(-50%) translateY(3px); }
}
@keyframes lilo-tt-out {
  to { opacity:0; transform:translateX(-50%) translateY(calc(-100% - 4px)); }
}
@keyframes lilo-tt-right-out {
  to { opacity:0; transform:translateY(-50%) translateX(-2px); }
}
@keyframes lilo-tt-left-out {
  to { opacity:0; transform:translateX(-100%) translateY(-50%) translateX(2px); }
}
@keyframes lilo-tt-bottom-out {
  to { opacity:0; transform:translateX(-50%) translateY(4px); }
}
@media (prefers-reduced-motion: reduce) {
  .lilo-tooltip, .lilo-tooltip.lilo-tooltip-leaving { animation: none; }
}`;
	document.head.appendChild(s);
}

export function tooltip(node: HTMLElement, params: TooltipParams) {
	inject();
	let text = "";
	let subtitle = "";
	let memory = "";
	let iconSrc = "";
	let iconText = "";
	let shortcut = "";
	let delay = DEFAULT_DELAY_MS;
	let placement: TooltipPlacement = "top";
	let disabled = false;
	let anchor = "";
	readParams(params);
	let resolvedPlacement: TooltipPlacement = placement;
	let timer: ReturnType<typeof setTimeout> | null = null;
	let removeTimer: ReturnType<typeof setTimeout> | null = null;
	let el: HTMLDivElement | null = null;
	let leavingEl: HTMLDivElement | null = null;
	const EXIT_DURATION_MS = 140;
	const controller: TooltipController = {
		cancelAndHide: () => {
			if (timer) {
				clearTimeout(timer);
				timer = null;
			}
			hideImmediately();
		},
	};

	function readParams(p: TooltipParams) {
		const o = typeof p === "string" ? { text: p } : p;
		text = o.text;
		subtitle = o.subtitle ?? "";
		memory = o.memory ?? "";
		iconSrc = o.iconSrc ?? "";
		iconText = o.iconText ?? "";
		shortcut = o.shortcut ?? "";
		delay = o.delay ?? DEFAULT_DELAY_MS;
		placement = o.placement ?? "top";
		disabled = o.disabled ?? false;
		anchor = o.anchor ?? "";
	}

	function show(instant = false) {
		if (disabled || !text || isSidebarDragActive()) {
			hideImmediately();
			return;
		}
		dismissOtherTooltips(controller);
		hideImmediately();
		el = document.createElement("div");
		resolvedPlacement = placement;
		el.className = classForPlacement();
		renderContent(el);
		if (instant) el.classList.add("lilo-tooltip-instant");
		document.body.appendChild(el);
		position();
	}

	function classForPlacement(p: TooltipPlacement = resolvedPlacement): string {
		const base = subtitle || memory ? "lilo-tooltip lilo-tooltip-rich" : "lilo-tooltip";
		return p === "right"
			? `${base} lilo-tooltip-right`
			: p === "left"
				? `${base} lilo-tooltip-left`
			: p === "bottom"
				? `${base} lilo-tooltip-bottom`
				: base;
	}

	function renderContent(target: HTMLDivElement) {
		target.replaceChildren();
		const rowEl = document.createElement("div");
		rowEl.className = "lilo-tooltip-row";
		if (iconSrc) {
			const iconEl = document.createElement("img");
			iconEl.className = "lilo-tooltip-icon";
			iconEl.src = iconSrc;
			iconEl.alt = "";
			rowEl.appendChild(iconEl);
		} else if (iconText) {
			const iconEl = document.createElement("span");
			iconEl.className = "lilo-tooltip-text-icon";
			iconEl.textContent = iconText;
			rowEl.appendChild(iconEl);
		}
		const titleEl = document.createElement("span");
		titleEl.className = "lilo-tooltip-title";
		titleEl.textContent = text;
		rowEl.appendChild(titleEl);
		if (shortcut) {
			const shortcutEl = document.createElement("span");
			shortcutEl.className = "lilo-tooltip-shortcut";
			shortcutEl.textContent = shortcut;
			rowEl.appendChild(shortcutEl);
		}
		target.appendChild(rowEl);
		if (!subtitle && !memory) return;
		const metaEl = document.createElement("div");
		metaEl.className = "lilo-tooltip-meta";
		if (subtitle) {
			const subtitleEl = document.createElement("span");
			subtitleEl.className = "lilo-tooltip-subtitle";
			subtitleEl.textContent = subtitle;
			metaEl.appendChild(subtitleEl);
		}
		if (memory) {
			const memoryEl = document.createElement("span");
			memoryEl.className = "lilo-tooltip-memory";
			memoryEl.textContent = memory;
			metaEl.appendChild(memoryEl);
		}
		target.appendChild(metaEl);
	}

	function position() {
		if (!el) return;
		const rect = ((anchor && node.closest<HTMLElement>(anchor)) || node).getBoundingClientRect();
		const MARGIN = 16;
		// Reserve the window-chrome header band (traffic lights, nav controls) so "top" tooltips never cover the URL-bar
		// buttons below it; topSafeInset measures the real header, falling back to a band that clears the traffic lights.
		const TOP_INSET = topSafeInset(MARGIN);

		// A "top" tooltip is pulled above its anchor by its own height + 7px. If that
		// would intrude into the reserved top band, flip it below the anchor instead.
		resolvedPlacement = placement;
		if (placement === "top") {
			const tooltipHeight = el.getBoundingClientRect().height;
			if (rect.top - tooltipHeight - 6 < TOP_INSET) {
				resolvedPlacement = "bottom";
			}
		}
		const cls = classForPlacement();
		const current = el.className.replace(/\s*lilo-tooltip-(leaving|instant)/g, "");
		if (current !== cls) {
			el.className = el.classList.contains("lilo-tooltip-instant") ? `${cls} lilo-tooltip-instant` : cls;
		}

		let left = rect.left + rect.width / 2;
		let top = rect.top;
		if (resolvedPlacement === "right") {
			left = rect.right + 8;
			top = rect.top + rect.height / 2;
		} else if (resolvedPlacement === "left") {
			left = rect.left - 8;
			top = rect.top + rect.height / 2;
		} else if (resolvedPlacement === "bottom") {
			top = rect.bottom;
		}

		// Force layout to get dimensions
		el.style.left = `${left}px`;
		el.style.top = `${top}px`;
		const elRect = el.getBoundingClientRect();

		// Boundary detection - keep tooltip within viewport
		if (resolvedPlacement === "right") {
			if (elRect.right > window.innerWidth - MARGIN) {
				left = Math.max(MARGIN, rect.left - elRect.width - 8);
				el.style.left = `${left}px`;
			}
			if (elRect.left < MARGIN) {
				left = MARGIN;
			}
		} else if (resolvedPlacement === "left") {
			if (elRect.left < MARGIN) left = rect.right + 8 + elRect.width;
		} else if (elRect.left < MARGIN) {
			left += MARGIN - elRect.left;
		} else if (elRect.right > window.innerWidth - MARGIN) {
			left -= elRect.right - window.innerWidth + MARGIN;
		}

		el.style.left = `${left}px`;
	}

	function hideImmediately() {
		if (removeTimer) {
			clearTimeout(removeTimer);
			removeTimer = null;
		}
		leavingEl?.remove();
		leavingEl = null;
		el?.remove();
		el = null;
	}

	function hide() {
		if (!el) {
			return;
		}
		el.className = `${el.className} lilo-tooltip-leaving`.trim();
		leavingEl = el;
		el = null;
		warmUntil = performance.now() + WARM_WINDOW_MS;
		removeTimer = setTimeout(() => {
			leavingEl?.remove();
			leavingEl = null;
			removeTimer = null;
		}, EXIT_DURATION_MS);
	}

	function enter() {
		if (disabled || isSidebarDragActive()) return;
		dismissOtherTooltips(controller);
		if (timer) clearTimeout(timer);
		// A longer, deliberate delay (tab rows) stays out of the warm window: sweeping the list
		// must not pop one tip per row.
		if (delay <= DEFAULT_DELAY_MS && performance.now() < warmUntil) {
			timer = null;
			show(true);
			return;
		}
		timer = setTimeout(show, delay);
	}

	function leave() {
		if (timer) {
			clearTimeout(timer);
			timer = null;
		}
		hide();
	}

	function handleSidebarDragStateChange() {
		if (isSidebarDragActive()) {
			if (timer) {
				clearTimeout(timer);
				timer = null;
			}
			hideImmediately();
		}
	}

	const globalHandlers: TooltipGlobalHandlers = {
		leave,
		suppressForDrag: handleSidebarDragStateChange,
	};
	node.addEventListener("mouseenter", enter);
	node.addEventListener("mouseleave", leave);
	node.addEventListener("click", leave);
	node.addEventListener("dragstart", leave);
	ensureGlobalTooltipListeners();
	tooltipGlobalHandlers.add(globalHandlers);
	tooltipControllers.add(controller);

	return {
		update(p: TooltipParams) {
			const rendered = el && [text, subtitle, memory, iconSrc, iconText, shortcut, placement];
			readParams(p);
			if (disabled || !text || isSidebarDragActive()) {
				if (timer) { clearTimeout(timer); timer = null; }
				hideImmediately();
				return;
			}
			if (el) {
				// A row patch (progress, loading) hands over a new params object with the same
				// content: rebuilding would re-decode the icon and re-measure for nothing.
				const next = [text, subtitle, memory, iconSrc, iconText, shortcut, placement];
				if (rendered && next.every((value, index) => value === rendered[index])) return;
				// Patch the visible tooltip in place so the entrance animation isn't
				// replayed on every content tick (e.g. live memory updates). position()
				// keeps the placement class in sync without re-triggering the animation.
				renderContent(el);
				position();
			}
		},
		destroy() {
			tooltipControllers.delete(controller);
			tooltipGlobalHandlers.delete(globalHandlers);
			node.removeEventListener("mouseenter", enter);
			node.removeEventListener("mouseleave", leave);
			node.removeEventListener("click", leave);
			node.removeEventListener("dragstart", leave);
			if (timer) clearTimeout(timer);
			hideImmediately();
		},
	};
}
