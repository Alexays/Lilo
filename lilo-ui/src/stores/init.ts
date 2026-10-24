import { type BridgeInitialStatePayload, on } from "../lib/bridge";
import { chromeActions } from "../lib/bridge/actions";
import { initBannersStore } from "./banners.svelte";
import { initOnboardingStore } from "./onboarding.svelte";
import { initPageHangStore } from "./pageHang.svelte";
import { initCommandBarStore } from "./commandBar.svelte";
import { initDownloadsStore } from "./downloads.svelte";
import {
	applyExtensionInitialState,
	initExtensionStore,
} from "./extensions.svelte";
import { initExtensionPinsStore } from "./extensionPins.svelte";
import { applyPagerInitialState, initPagerStore } from "./pager.svelte";
import { initPanelsStore } from "./panels.svelte";
import { initPipDockStore } from "./pipDock.svelte";
import { initPowerStore } from "./power.svelte";
import { initSidePanelStore } from "./sidePanel";
import { initSplitPanesStore } from "./splitPanes.svelte";
import { initKeepAwakeStore } from "./keepAwake.svelte";
import { initAgentsStore } from "./agents.svelte";
import { initMediaStore } from "./media.svelte";
import { applyProfileInitialState, initProfileStore } from "./profiles.svelte";
import { initScreenshotEditor } from "./screenshotEditor.svelte";
import { initSearchEngineStore } from "./searchEngines";
import { initSettingsStore } from "./settings.svelte";
import { initShortcutKeysStore } from "./shortcutKeys.svelte";
import { applySpaceInitialState, initSpaceStore } from "./spaces.svelte";
import { initTabMemoryStore } from "./tabMemory.svelte";
import { initTabShareStore } from "./tabShare.svelte";
import { initTabSwitcherStore } from "./tabSwitcher.svelte";
import { initUndoToastStore } from "./undoToast.svelte";
import { initCaptureCardStore } from "./captureCard.svelte";
import { initUrlBarDrawerStore } from "./urlBarDrawer.svelte";
import { initFolderLockStore } from "./folderLock.svelte";
import { applySidebarFolderInitialState, applySidebarTabInitialState } from "./sidebar.svelte";
import { initTabStore } from "./tabs.svelte";
import { applyUIInitialState, initUIStore } from "./ui.svelte";
import { createStartupMarkRecorder } from "./startupMarks";

type InitialStateApplier = (data: BridgeInitialStatePayload) => void;
type StoreInitializer = () => void;
type InitialStateReadyListener = () => void;

const CRITICAL_STORES: StoreInitializer[] = [
	initTabStore,
	initSpaceStore,
	initProfileStore,
	initUIStore,
	initCommandBarStore,
	initBannersStore,
	// The sidebar shows a hung tab from any tab, from the first paint.
	initPageHangStore,
	initOnboardingStore,
	// The address bar is first-paint chrome, and a permission request may arrive before the
	// deferred stores start.
	initUrlBarDrawerStore,
];

const DEFERRED_STORES: StoreInitializer[] = [
	initExtensionStore,
	initShortcutKeysStore,
	initFolderLockStore,
	initExtensionPinsStore,
	initPanelsStore,
	initPagerStore,
	initPowerStore,
	initSidePanelStore,
	initSplitPanesStore,
	initKeepAwakeStore,
	initAgentsStore,
	initMediaStore,
	initScreenshotEditor,
	initSearchEngineStore,
	initSettingsStore,
	initTabMemoryStore,
	initTabShareStore,
	initTabSwitcherStore,
	initUndoToastStore,
	initCaptureCardStore,
	initPipDockStore,
	initDownloadsStore,
];

const CRITICAL_STATE_APPLIERS: InitialStateApplier[] = [
	applyInitialGeometry,
	applyUIInitialState,
	applySpaceInitialState,
	applyProfileInitialState,
	applySidebarTabInitialState,
	applySidebarFolderInitialState,
];

const DEFERRED_STATE_APPLIERS: InitialStateApplier[] = [
	applyExtensionInitialState,
	applyPagerInitialState,
];

let initialStateApplied = false;
let deferredStoresReady = false;
let pendingDeferredState: BridgeInitialStatePayload | undefined;
const initialStateReadyListeners = new Set<InitialStateReadyListener>();
const recordStartupMark = createStartupMarkRecorder((event) => {
	chromeActions.startupMark(event);
});

function applyInitialGeometry(
	data: Pick<
		BridgeInitialStatePayload,
		"sidebarWidth" | "windowBackgroundColor"
	>,
): void {
	applySidebarWidth(data.sidebarWidth);
	applyWindowBackgroundColor(data.windowBackgroundColor);
}

function applyInitialState(data: BridgeInitialStatePayload): void {
	recordStartupMark("chromeInitialStateReceived");

	for (const apply of CRITICAL_STATE_APPLIERS) {
		apply(data);
	}
	recordStartupMark("chromeInitialStateCriticalApplied");

	if (deferredStoresReady) {
		for (const apply of DEFERRED_STATE_APPLIERS) {
			apply(data);
		}
		recordStartupMark("chromeInitialStateDeferredApplied");
	} else {
		pendingDeferredState = data;
	}

	if (!initialStateApplied) {
		initialStateApplied = true;
		// The host builds the active tab's web view on this: earlier, it would hold the main thread the
		// chrome's own load needs.
		chromeActions.initialStateApplied();
		recordStartupMark("chromeInitialStateReadyNotified");
		for (const listener of initialStateReadyListeners) {
			listener();
		}
		initialStateReadyListeners.clear();
	}
}

function applySidebarWidth(sidebarWidth: number): void {
	if (typeof document === "undefined") {
		return;
	}

	if (!Number.isFinite(sidebarWidth) || sidebarWidth <= 0) {
		return;
	}

	document.documentElement.style.setProperty(
		"--sidebar-width",
		`${sidebarWidth}px`,
	);
}

function applyWindowBackgroundColor(windowBackgroundColor?: string): void {
	if (typeof document === "undefined" || !windowBackgroundColor) {
		return;
	}

	document.documentElement.style.setProperty(
		"--sidebar-bg",
		windowBackgroundColor,
	);
}

export function onChromeInitialStateReady(
	listener: InitialStateReadyListener,
): () => void {
	if (initialStateApplied) {
		listener();
		return () => {};
	}

	initialStateReadyListeners.add(listener);
	return () => initialStateReadyListeners.delete(listener);
}

function initializeStores(): void {
	for (const init of CRITICAL_STORES) init();

	queueMicrotask(() => {
		for (const init of DEFERRED_STORES) init();
		deferredStoresReady = true;

		if (pendingDeferredState) {
			for (const apply of DEFERRED_STATE_APPLIERS) {
				apply(pendingDeferredState);
			}
			recordStartupMark("chromeInitialStateDeferredApplied");
			pendingDeferredState = undefined;
		}
	});
}

export function initChromeStores(initialState?: BridgeInitialStatePayload): void {
	initializeStores();
	on("initialState", applyInitialState);
	if (initialState) applyInitialState(initialState);
}
