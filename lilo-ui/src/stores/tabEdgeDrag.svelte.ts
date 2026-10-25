import type { TabPosition } from "../lib/bridge";
import { chromeActions } from "../lib/bridge/actions";
import { getTabPosition, setTabPosition } from "./tabLayout.svelte";

const HOLD_MS = 400;
const MOVE_TOLERANCE_PX = 4;
// An edge takes the tabs only while the pointer is in the outer share of the window toward it.
const EDGE_REACH = 0.3;

let _lifting = $state(false);
let _target = $state<TabPosition | null>(null);
const handled = new WeakSet<Event>();

export function isLiftingTabs(): boolean {
	return _lifting;
}

export function getTabEdgeTarget(): TabPosition | null {
	return _target;
}

function nearestEdge(x: number, y: number): TabPosition | null {
	const width = window.innerWidth;
	const height = window.innerHeight;
	const reach: [TabPosition, number][] = [
		["left", x / width],
		["right", (width - x) / width],
		["top", y / height],
		["bottom", (height - y) / height],
	];
	const [edge, share] = reach
		.filter(([edge]) => edge !== getTabPosition())
		.sort((a, b) => a[1] - b[1])[0];
	return share < EDGE_REACH ? edge : null;
}

function setLifting(lifting: boolean): void {
	_lifting = lifting;
	_target = null;
	if (lifting) document.documentElement.dataset.tabsLifting = "";
	else delete document.documentElement.dataset.tabsLifting;
}

/**
 * An empty spot of the tabs' header or strip: a press that moves drags the window as before,
 * a press held still lifts the tabs to drop them on another edge.
 */
export function pressTabsHeader(event: PointerEvent): void {
	// A control-click is a right click on the Mac: its menu takes the release.
	if (event.button !== 0 || event.ctrlKey || handled.has(event)) return;
	const target = event.target as HTMLElement | null;
	if (target?.closest("button, a, input, select, textarea, [role='button'], .url-display, .strip-tab")) return;
	handled.add(event);
	const startX = event.clientX;
	const startY = event.clientY;
	let timer: ReturnType<typeof setTimeout> | null = setTimeout(lift, HOLD_MS);

	function stopWaiting(): void {
		if (timer !== null) clearTimeout(timer);
		timer = null;
	}

	function onMove(move: PointerEvent): void {
		if (_lifting) {
			_target = nearestEdge(move.clientX, move.clientY);
			return;
		}
		if (Math.hypot(move.clientX - startX, move.clientY - startY) <= MOVE_TOLERANCE_PX) return;
		finish();
		chromeActions.startWindowDrag();
	}

	function onUp(): void {
		const target = _lifting ? _target : null;
		finish();
		if (target) setTabPosition(target);
	}

	function onKey(key: KeyboardEvent): void {
		if (key.key !== "Escape" || !_lifting) return;
		key.preventDefault();
		key.stopPropagation();
		finish();
	}

	function lift(): void {
		timer = null;
		setLifting(true);
	}

	function finish(): void {
		stopWaiting();
		if (_lifting) setLifting(false);
		window.removeEventListener("pointermove", onMove, true);
		window.removeEventListener("pointerup", onUp, true);
		window.removeEventListener("keydown", onKey, true);
		window.removeEventListener("pointercancel", finish, true);
		window.removeEventListener("contextmenu", finish, true);
		window.removeEventListener("blur", finish);
	}

	window.addEventListener("pointermove", onMove, true);
	window.addEventListener("pointerup", onUp, true);
	window.addEventListener("keydown", onKey, true);
	// A press that ends elsewhere (a menu, another app) must not leave the tabs lifted.
	window.addEventListener("pointercancel", finish, true);
	window.addEventListener("contextmenu", finish, true);
	window.addEventListener("blur", finish);
}
