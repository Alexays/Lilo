import { on, type AddressPlacement, type BridgeInitialStatePayload, type TabPosition } from "../lib/bridge";
import { setSetting } from "./settings.svelte";

let _position = $state<TabPosition>("left");
let _address = $state<AddressPlacement>("tabs");

/** Right and bottom keep a toolbar over the page for the traffic lights, so the address goes there. */
function defaultAddress(position: TabPosition): AddressPlacement {
	return position === "right" || position === "bottom" ? "page" : "tabs";
}

function apply(position: TabPosition, address: AddressPlacement): void {
	_position = position;
	_address = address;
	if (typeof document === "undefined") return;
	const root = document.documentElement;
	root.dataset.tabPosition = position;
	root.dataset.address = address;
}

export function applyTabLayoutInitialState(data: Pick<BridgeInitialStatePayload, "tabPosition" | "addressPlacement">): void {
	const position = data.tabPosition ?? "left";
	apply(position, (position !== "right" && data.addressPlacement) || defaultAddress(position));
}

/** On the right the address always sits above the page: the sidebar's first line is the toolbar's. */
export function isAddressLocked(): boolean {
	return _position === "right";
}

export function initTabLayoutStore(): void {
	on("tabLayoutChanged", ({ position, address }) => apply(position, address));
}

export function getTabPosition(): TabPosition {
	return _position;
}

export function getAddressPlacement(): AddressPlacement {
	return _address;
}

export function isVerticalLayout(): boolean {
	return _position === "left" || _position === "right";
}

/** A row over the page's width: always on the right and bottom, where it keeps the traffic lights. */
export function hasPageToolbar(): boolean {
	return _position === "right" || _position === "bottom" || (_position === "left" && _address === "page");
}

export function isAddressInPageToolbar(): boolean {
	return hasPageToolbar() && _address === "page";
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
