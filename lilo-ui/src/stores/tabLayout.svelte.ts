import { on, type AddressPlacement, type BridgeInitialStatePayload, type TabPosition } from "../lib/bridge";
import { setSetting } from "./settings.svelte";
import { getActiveUrlBarDrawer } from "./urlBarDrawer.svelte";
import { tick } from "svelte";
import { prefersReducedMotion } from "../lib/motion/reducedMotion";
import { isSidebarVisible } from "./ui.svelte";
import { getOnboarding } from "./onboarding.svelte";

let _position = $state<TabPosition>("left");
let _address = $state<AddressPlacement>("tabs");
let _toolbarVisible = $state(true);

/** Right and bottom keep a toolbar over the page for the traffic lights, so the address goes there. */
function defaultAddress(position: TabPosition): AddressPlacement {
	return position === "right" || position === "bottom" ? "page" : "tabs";
}

let applied = false;
let latestApply = 0;
// Well past the morph's own length (--motion-duration-slow).
const MORPH_DEADLINE_MS = 1000;

function apply(position: TabPosition, address: AddressPlacement): void {
	const update = () => {
		_position = position;
		_address = address;
		if (typeof document === "undefined") return;
		const root = document.documentElement;
		root.dataset.tabPosition = position;
		root.dataset.address = shownAddress();
	};
	// A new edge morphs the tabs there (global.css names them), while the native page slides alongside.
	// Not under the onboarding: the morph paints in the top layer, over any z-index.
	const morph = applied && position !== _position && !getOnboarding().visible && typeof document !== "undefined" && "startViewTransition" in document && !prefersReducedMotion();
	applied = true;
	const thisApply = ++latestApply;
	if (!morph) return update();
	const transition = document.startViewTransition(async () => {
		// A global outro inside the old tabs keeps them in the page a while: only the new ones may carry the name.
		const leaving = isVerticalLayout() === (position === "top" || position === "bottom") ? document.querySelector<HTMLElement>("#chrome-root > .sidebar, .tab-strip-host") : null;
		update();
		await tick();
		if (leaving) leaving.style.viewTransitionName = "none";
	});
	// Lilo's WebKit can leave a morph unfinished: its frozen snapshot would cover the chrome and take its clicks.
	const deadline = setTimeout(() => transition.skipTransition(), MORPH_DEADLINE_MS);
	void transition.finished.finally(() => {
		clearTimeout(deadline);
		// A skipped morph may never run its update: the tabs would stay on the edge the page just left.
		if (thisApply === latestApply) update();
	});
}

export function applyTabLayoutInitialState(data: Pick<BridgeInitialStatePayload, "tabPosition" | "addressPlacement" | "toolbarVisible">): void {
	_toolbarVisible = data.toolbarVisible ?? true;
	const position = data.tabPosition ?? "left";
	const address = data.addressPlacement ?? defaultAddress(position);
	apply(position, address);
}

export function initTabLayoutStore(): void {
	on("tabLayoutChanged", ({ position, address }) => apply(position, address));
	on("toolbarVisibilityChanged", ({ visible }) => {
		_toolbarVisible = visible;
		if (typeof document !== "undefined") document.documentElement.dataset.address = shownAddress();
	});
}

/** On the left and the top, the toolbar holds only the address: it hides apart from the tabs. */
export function canHideToolbar(): boolean {
	return _address === "page" && (_position === "left" || _position === "top");
}

/** The address as drawn: a hidden toolbar takes it along, as if the setting hid it. */
function shownAddress(): AddressPlacement {
	return canHideToolbar() && !_toolbarVisible ? "hidden" : _address;
}

export function getTabPosition(): TabPosition {
	return _position;
}

export function getAddressPlacement(): AddressPlacement {
	return _address;
}

/** Requests must remain answerable even when the address is hidden. */
export function isAddressVisible(): boolean {
	return shownAddress() !== "hidden" || getActiveUrlBarDrawer() !== null;
}

export function isVerticalLayout(): boolean {
	return _position === "left" || _position === "right";
}

/** A row over the page's width: always on the right and bottom, where it keeps the traffic lights. */
export function hasPageToolbar(): boolean {
	return _position === "right" || _position === "bottom" || (_position === "left" && shownAddress() === "page");
}

/** The tabs' own toolbar goes with them; the address's own one, on the left and the top, stays on its own. */
export function isPageToolbarShown(): boolean {
	return canHideToolbar() ? _toolbarVisible : hasPageToolbar() && isSidebarVisible();
}

/** On the right, an address with the tabs heads their column with the history buttons; the toggle stays by the lights. */
export function isAddressInRightTabs(): boolean {
	return _position === "right" && _address === "tabs";
}

export function isAddressInPageToolbar(): boolean {
	return isPageToolbarShown() && shownAddress() === "page";
}

/** The side a row's tooltip or card opens toward: away from the sidebar. */
export function tooltipSide(): "left" | "right" {
	return _position === "right" ? "left" : "right";
}

export function setTabPosition(position: TabPosition): void {
	setSetting("tabPosition", position);
}

export function setAddressPlacement(address: AddressPlacement): void {
	setSetting("addressPlacement", address);
}
