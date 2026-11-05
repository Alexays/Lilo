import { on, type BridgeInitialStatePayload } from "../lib/bridge";
import { chromeActions } from "../lib/bridge/actions";

type SidebarMode = "visible" | "overlay" | "hidden";

let _sidebarMode = $state<SidebarMode>("visible");

/** The content edges in global.css give the page every edge while the tabs are not docked. */
function setSidebarMode(mode: SidebarMode): void {
	_sidebarMode = mode;
	if (typeof document === "undefined") return;
	if (mode === "visible") delete document.documentElement.dataset.tabsHidden;
	else document.documentElement.dataset.tabsHidden = "";
}
let _sidebarRail = $state(false);

/** global.css docks the page beside the rail while the tabs are on the left or the right. */
function applySidebarRail(rail: boolean): void {
	_sidebarRail = rail;
	if (typeof document === "undefined") return;
	if (rail) document.documentElement.dataset.sidebarRail = "";
	else delete document.documentElement.dataset.sidebarRail;
}
let _trafficLightsVisible = $state<boolean>(true);
let _isFullscreen = $state<boolean>(false);

export function applyUIInitialState(data: BridgeInitialStatePayload): void {
	setSidebarMode(data.sidebarVisible ? "visible" : "hidden");
	applySidebarRail(data.sidebarRail ?? false);
	_trafficLightsVisible = data.trafficLightsVisible ?? true;
	_isFullscreen = data.isFullscreen ?? false;
}

export function initUIStore(): void {
	on("sidebarVisibilityChanged", (data) => {
		setSidebarMode(data.visible ? "visible" : "hidden");
	});

	on("windowChromeStateChanged", (data) => {
		_trafficLightsVisible = data.trafficLightsVisible ?? true;
	});

	on("windowFullscreenChanged", (data) => {
		_isFullscreen = data.isFullscreen;
	});
}

export function isSidebarVisible(): boolean {
	return _sidebarMode === "visible";
}

export function isSidebarOverlay(): boolean {
	return _sidebarMode === "overlay";
}

export function isSidebarShown(): boolean {
	return _sidebarMode !== "hidden";
}

/** Folded to its icon rail; it only shows with the tabs on the left or the right. */
export function isSidebarRail(): boolean {
	return _sidebarRail;
}

export function setSidebarRail(rail: boolean): void {
	if (rail === _sidebarRail) return;
	applySidebarRail(rail);
	chromeActions.setSidebarRail(rail);
}

export function areTrafficLightsVisible(): boolean {
	return _trafficLightsVisible;
}

export function showSidebarOverlay(): void {
	if (_sidebarMode === "hidden") {
		setSidebarMode("overlay");
		chromeActions.sidebarOverlayChanged(true);
	}
}

export function hideSidebarOverlay(): void {
	if (_sidebarMode === "overlay") {
		setSidebarMode("hidden");
		chromeActions.sidebarOverlayChanged(false);
	}
}

export function isFullscreen(): boolean {
	return _isFullscreen;
}
