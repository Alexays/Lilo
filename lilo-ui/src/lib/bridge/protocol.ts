import type { BridgeTabSnapshot } from "./tabProtocol.gen";

export type EmptyPayload = Record<string, never>;

/** A capture to save or copy: native writes its own PNG of capture `id` (cropped to `crop`), or
 * the editor's flattened `dataURL` when there are annotations to bake in. */
export interface BridgeTabShareAudio {
	system: "granted" | "denied" | "undetermined" | "unsupported";
	systemOn: boolean;
}

export interface ScreenshotExport {
	id: string;
	dataURL?: string;
	crop?: { x: number; y: number; w: number; h: number } | null;
}

export type BridgeSidebarItemKind = "tab" | "folder";
export type BridgeSidebarTreeSection = "bookmarked" | "pinned" | "unpinned";
type BridgeSidebarFolderSection = Exclude<BridgeSidebarTreeSection, "bookmarked">;
export type SplitSide = "left" | "right" | "top" | "bottom";

export type ImportKind = "bookmarks" | "tabs" | "history" | "cookies" | "extensions";

export interface ImportProfileInfo {
	id: string;
	name: string;
	kinds: ImportKind[];
	extensions: { id: string; name: string }[];
}

export interface ImportSourceInfo {
	id: string;
	name: string;
	family: "chromium" | "safari" | "firefox";
	/** The installed browser's own icon; empty when macOS cannot resolve the app. */
	iconDataURL: string;
	needsFullDiskAccess: boolean;
	profiles: ImportProfileInfo[];
}

export interface ImportSelection {
	sourceId: string;
	profileId: string;
	kinds: ImportKind[];
	extensionIds: string[];
}

/** `kind` of that profile has started, at `done` of `total` (0 when its size is unknown). */
export interface ImportProgress {
	sourceId: string;
	profileId: string;
	kind: ImportKind;
	done: number;
	total: number;
}

export interface ImportSummaryItem {
	sourceId: string;
	profileId: string;
	kind: ImportKind;
	imported: number;
	error?: string;
}
/** Where a tab dropped on a pane lands: one of its edges, or in its place once the split is full. */
export type SplitDropSide = SplitSide | "replace";
export const MAX_SPLIT_PANES = 4;

/** A split's shape: one tab per leaf; `first` is the left part, or the top one when vertical. */
export type BridgeSplitLayout =
	| { tabId: string }
	| { vertical: boolean; first: BridgeSplitLayout; second: BridgeSplitLayout };

/** A pane's frame as shares of the content area, from its top-left corner. */
export interface BridgeSplitPaneFrame {
	tabId: string;
	x: number;
	y: number;
	width: number;
	height: number;
}

type BridgeSidebarDropAnchors = {
	fallbackIndex: number;
	insertBeforeId?: string | null;
	insertAfterId?: string | null;
};

export type BridgeSidebarRootInsertPayload = BridgeSidebarDropAnchors & {
	type: "insert";
	kind: BridgeSidebarItemKind;
	id: string;
	section: BridgeSidebarFolderSection;
	parentFolderId: null;
};

export type BridgeSidebarFolderInsertPayload = BridgeSidebarDropAnchors & {
	type: "insert";
	kind: BridgeSidebarItemKind;
	id: string;
	section: BridgeSidebarFolderSection;
	parentFolderId: string;
};

export type BridgeSidebarBookmarkInsertPayload = BridgeSidebarDropAnchors & {
	type: "insert";
	kind: "tab";
	id: string;
	section: "bookmarked";
	parentFolderId: null;
};

export type BridgeSidebarDropPayload =
	| BridgeSidebarRootInsertPayload
	| BridgeSidebarFolderInsertPayload
	| BridgeSidebarBookmarkInsertPayload
	| {
			type: "group";
			sourceTabId: string;
			targetTabId: string;
	  };

export interface BridgeFolderLock {
	allowsBiometrics: boolean;
	biometricsAvailable: boolean;
}

export interface BridgeTabFolderSnapshot {
	id: string;
	spaceId: string;
	name: string;
	color: string;
	isCollapsed: boolean;
	isSplit?: boolean;
	splitLayout?: BridgeSplitLayout;
	isLocked?: boolean;
	lock?: BridgeFolderLock | null;
}

// BridgeTabSnapshot is generated from bridge-schema/tab.json, edit the schema, run `make bridge-gen`.
export type { BridgeTabSnapshot } from "./tabProtocol.gen";

export interface BridgeSidebarTreeItemSnapshot {
	id: string;
	spaceId: string;
	kind: BridgeSidebarItemKind;
	itemId: string;
	parentFolderId?: string | null;
	section: BridgeSidebarTreeSection;
	sortOrder: number;
}

export interface BridgeSpaceSnapshot {
	id: string;
	name: string;
	icon: string;
	color: string;
	profileId: string;
	isPrivate: boolean;
	sortOrder: number;
	/** Idle hours before a top-level unpinned tab is archived; 0 never archives. */
	archiveAfterHours?: number;
	/** Where the chrome color comes from; `color` is the base the other modes light or fall back to. */
	colorMode?: SpaceColorMode;
}

export type SpaceColorMode = "fixed" | "time" | "page" | "wallpaper";

export interface BridgeSpaceBrowserStatePayload {
	spaceId: string;
	activeTabId: string;
	tabs: BridgeTabSnapshot[];
	folders: BridgeTabFolderSnapshot[];
	treeItems: BridgeSidebarTreeItemSnapshot[];
}

export interface BridgeBrowserStateChangedPayload {
	changedSpaceId: string;
	profileId?: string;
	transitionId?: string;
	states: BridgeSpaceBrowserStatePayload[];
	/** Wire-order sequence number stamped by `StateSequencer` in Swift. Absent on pre-seq messages. */
	stateSeq?: number;
}

export interface BridgeTabUpdatedPayload {
	spaceId: string;
	activeTabId: string;
	tab: BridgeTabSnapshot;
}

/**
 * Absent fields mean "unchanged" (treeItems) or "none" (upserts/removals). A diff against a space the UI doesn't
 * hold hydrated must be ignored: the fullState sent on space switch resyncs it.
 */
export interface BridgeSidebarChangedPayload {
	spaceId: string;
	activeTabId: string;
	/** The whole tree; otherwise `upsertTreeItems` and `removedTreeItemIds`, keyed by `itemId`, patch the held one. */
	treeItems?: BridgeSidebarTreeItemSnapshot[];
	upsertTreeItems?: BridgeSidebarTreeItemSnapshot[];
	removedTreeItemIds?: string[];
	upsertTabs?: BridgeTabSnapshot[];
	removedTabIds?: string[];
	upsertFolders?: BridgeTabFolderSnapshot[];
	removedFolderIds?: string[];
}

export type BridgeBrowserStatePatchOperation =
	| ({ kind: "tabUpdated" } & BridgeTabUpdatedPayload)
	| ({ kind: "sidebarChanged" } & BridgeSidebarChangedPayload);

export interface BridgeBrowserStatePatchPayload {
	operations: BridgeBrowserStatePatchOperation[];
	/** Wire-order sequence number stamped by `StateSequencer` in Swift. Absent on pre-seq messages. */
	stateSeq?: number;
}

export interface BridgeProfileSnapshot {
	id: string;
	name: string;
	isDefault: boolean;
	color: string;
}

export interface BridgeExtensionSnapshot {
	id: string;
	name: string;
	version: string;
	description: string;
	isEnabled: boolean;
	iconDataURL?: string | null;
	iconVersion?: number;
	hasPopup: boolean;
	hasBackground: boolean;
	hasContentScripts: boolean;
	/** "loaded" (healthy), "degraded" (background stopped) or "failed" (could not load at all). */
	runtimeStatus?: string;
	/** Why the extension is degraded or failed; empty otherwise. */
	error?: string;
	/** A newer version found while automatic updates are off. */
	availableUpdate?: string;
	/** A newer version whose added permissions the user declined. */
	declinedUpdate?: string;
	/** The extension's store page, set only for a copy installed from the Chrome Web Store. */
	webStoreURL?: string;
	allowsPrivateAccess?: boolean;
	/** The "Allow user scripts" switch, shown for extensions declaring `userScripts`. */
	allowsUserScripts?: boolean;
	/** The extension asks for the active tab's site (chrome.permissions.addHostAccessRequest). */
	hostAccessRequest?: boolean;
	commands?: BridgeExtensionCommand[];
	badgeText: string;
	badgeColor: string;
	badgeTextColor?: string;
	/** The toolbar action's own state for the active tab (action.enable/disable, action.setTitle). */
	actionEnabled?: boolean;
	actionLabel?: string;
	permissions?: string[];
	hostPermissions?: string[];
	/** Hosts the extension is restricted to; empty means every host its manifest asked for. */
	siteAccess?: string[];
	omniboxKeyword?: string;
}

export interface BridgeExtensionCommand {
	id: string;
	title: string;
	/** Empty when the command has no shortcut. */
	key: string;
	/** NSEvent.ModifierFlags raw value. */
	modifiers: number;
}

/** Outcome of the last extension update check; `lastCheck` is in seconds since the epoch. */
export interface BridgeExtensionUpdateCheck {
	checking?: boolean;
	lastCheck?: number;
	updated?: number;
	available?: number;
	failed?: number;
}

interface BridgeHistoryResultSnapshot {
	url: string;
	title: string;
	[key: string]: unknown;
}

export interface BridgeDownloadSnapshot {
	id: number;
	url: string;
	filename: string;
	bytesReceived: number;
	totalBytes: number;
	state: "inProgress" | "paused" | "complete" | "interrupted";
	startedAt: number;
	endedAt?: number;
	error?: string;
	fileMissing: boolean;
	source: "wk" | "url";
	speedBytesPerSec?: number;
	eta?: number;
}

export interface BridgeWebsiteDataSnapshot {
	name: string;
	kinds: ("cache" | "cookies" | "storage")[];
}

export type BridgeBrowsingDataKind = "history" | "cookies" | "cache" | "siteData";

/** Bytes the window's profile stores, by kind; a kind left out could not be measured. */
export interface BridgeBrowsingDataSizes {
	history?: number;
	historyEntries?: number;
	cache?: number;
	cookies?: number;
	storage?: number;
}

export interface BridgeZoomLevelSnapshot {
	host: string;
	zoom: number;
}

/** The content blocker's filter lists: counts from the last conversion, times in seconds since 1970. */
export interface BridgeContentBlockerStatus {
	updating: boolean;
	lists: number;
	updated?: number;
}

/** The devices remembered for the connected displays; names of the roles that have one. */
export interface BridgeDeviceSetupSnapshot {
	label: string;
	camera?: string;
	input?: string;
	output?: string;
}

export interface BridgeSitePermissionSnapshot {
	id: string;
	origin: string;
	type: string;
	decision: string;
	updatedAt: number;
}

export interface BridgeSettingsActionStatusPayload {
	action: string;
	message: string;
	level: "info" | "error";
}

export interface BridgeExtensionDiagnosticSnapshot {
	id: string;
	timestamp: number;
	level: "info" | "warning" | "error";
	source: string;
	extensionId: string;
	message: string;
	metadata: Record<string, string>;
}

export interface BridgeStartupMetricSummary {
	chromeVisualReadyMilliseconds?: number;
	bootDurationMilliseconds?: number;
}

export interface BridgeTabLifecycleDiagnostics {
	trackedSpaceCount: number;
	activeSpaceEngineCount: number;
	hiddenSpaceEngineCount: number;
	totalLiveEngineCount: number;
	restoringTabCount: number;
	savedInteractionStateCount: number;
	discardedOpenTabCount: number;
	hiddenSpacesWithNormalRetainedEngines: number;
}

export type BridgeProcessKind =
	| "webContent"
	| "provisionalWebContent"
	| "network"
	| "gpu"
	| "model";

export interface BridgeProcessTabInfo {
	id: string;
	spaceId: string;
	title: string;
	url: string;
	lifecycle:
		| "active"
		| "loaded-hidden"
		| "frozen"
		| "restoring"
		| "discarded"
		| "unknown";
	isAudioPlaying: boolean;
	isMicrophoneActive: boolean;
	isCameraActive: boolean;
	isScreenSharing: boolean;
	isPictureInPictureActive?: boolean | null;
}

export interface BridgeProcessInfo {
	id: string;
	kind: BridgeProcessKind;
	pid: number;
	tabs: BridgeProcessTabInfo[];
	metrics?: { residentSizeBytes: number; cpuPercent?: number | null } | null;
	webProcessStateLabel: string;
	webProcessIsResponsive?: boolean | null;
}

export interface BridgeProcessSnapshot {
	processes: BridgeProcessInfo[];
}

export interface BridgeProcessManagerActionStatusPayload {
	action: string;
	message: string;
	level: "info" | "error";
}

export interface BridgeStartupMetricMarkSnapshot {
	id: string;
	timestamp: number;
	event: string;
	totalMilliseconds: number;
	deltaMilliseconds: number;
}

export interface BridgeStartupTraceSnapshot {
	id: string;
	timestamp: number;
	category: string;
	message: string;
	totalMilliseconds: number;
}

interface BridgePermissionRequestPayload {
	requestId: string;
	// Tab that asked: the prompt is only rendered while that tab is the active one.
	tabId: string;
	type: string;
	origin: string;
}

interface BridgeExtensionPermissionRequestPayload {
	requestId: string;
	extensionId: string;
	extensionName: string;
	permissions: string[];
	origins: string[];
	type: 'permissions' | 'urls' | 'matchPatterns';
}

export type TabPosition = "left" | "right" | "top" | "bottom";
export type AddressPlacement = "tabs" | "page";

export interface BridgeInitialStatePayload {
	tabs: BridgeTabSnapshot[];
	folders?: BridgeTabFolderSnapshot[];
	treeItems: BridgeSidebarTreeItemSnapshot[];
	activeTabId: string;
	sidebarWidth: number;
	sidebarVisible: boolean;
	trafficLightsVisible?: boolean;
	tabPosition?: TabPosition;
	addressPlacement?: AddressPlacement;
	isFullscreen?: boolean;
	windowBackgroundColor?: string;
	spaces?: BridgeSpaceSnapshot[];
	activeSpaceId?: string;
	profiles?: BridgeProfileSnapshot[];
	activeProfileId?: string;
	extensions?: BridgeExtensionSnapshot[];
	tracingEnabled?: boolean;
}

export interface BridgeFeatureFlagSnapshot {
	key: string;
	name: string;
	details: string;
	kind: "experimental" | "debug";
	enabled: boolean;
	modified: boolean;
}

export interface BridgeCommandPayloadMap {
	/** Posted by the native boot script, never by the chrome. */
	ready: { at: number };
	startupMark: { event: string; at: number };
	chromeVisualReady: { at: number };
	initialStateApplied: EmptyPayload;
	traceSpaceSwipe: {
		stage: string;
		source?: "click" | "swipe" | "ui";
		activeSpaceId?: string;
		focusedSpaceId?: string;
		targetId?: string;
		transitionId?: string;
		virtualIndex?: number;
		scrollLeft?: number;
		width?: number;
		anchorIndex?: number;
	};
	traceSpaceDnd: {
		stage: string;
		event: "consider" | "finalize" | "mousedown";
		id: string;
		trigger: string;
		source: string;
		shadowIndex: number;
		baseOrder: string;
		itemsOrder: string;
		visualOrder: string;
	};
	sidebarResized: { width: number };
	toggleSidebar: EmptyPayload;
	setSidebarCollapseLocked: { locked: boolean };
	maximizeWindow: EmptyPayload;
	startWindowDrag: EmptyPayload;
	registerInteractiveZones: {
		zones: { id: string; x: number; y: number; width: number; height: number }[];
	};
	removeInteractiveZone: { id: string };
	// `remember` false: a dismissal, denied for now without storing a decision for the site.
	permissionResponse: { requestId: string; granted: boolean; remember?: boolean };
	extensionPermissionResponse: { requestId: string; granted: boolean };
	updateWindowBackground: { color: string };
	setWallpaperColorWatch: { enabled: boolean };
	sidebarOverlayChanged: { visible: boolean };
	showTabSecurityInfo: EmptyPayload;
	showTabContextMenu: { id: string; x: number; y: number; width: number; height: number };
	showFolderContextMenu: { id: string; x: number; y: number; width: number; height: number };
	showSidebarContextMenu: { x: number; y: number; width: number; height: number; spaceId?: string };
	showBackHistoryMenu: { x: number; y: number; width: number; height: number };
	showForwardHistoryMenu: {
		x: number;
		y: number;
		width: number;
		height: number;
	};
	getRecentHistory: EmptyPayload;

	// typed: the URL the user typed in the command bar, which native may send to the site history knows.
	createTab: { url?: string; typed?: boolean };
	closeTab: { id: string };
	switchTab: { id: string };
	// The tab the recent tabs switcher picked, in whichever Space of the window it lives.
	switchToRecentTab: { id: string };
	// Show here the selected tab another window shows.
	claimTab: { id: string };
	// Open the tab in a new window whose top-left lands at this screen point (CSS px, top-left origin).
	moveTabToNewWindow: { id: string; screenX: number; screenY: number };
	unpinTab: { id: string };
	bookmarkTab: { id: string };
	unbookmarkTab: { id: string };
	// A blank title gives the tab its page title back.
	renameTab: { id: string; title: string };
	// A pinned or bookmarked tab's home page: the page it opens on and returns to.
	setTabHomeURL: { id: string; url: string };
	// Load a pinned or bookmarked tab's home page again.
	returnTabHome: { id: string };
	muteTab: { id: string };
	unmuteTab: { id: string };
	controlMedia: { id: string; action: BridgeMediaAction };
	controlCall: { id: string; action: BridgeCallAction };
	shareTabInstead: { token: string; tabId: string };
	stopTabShare: { token: string };
	getMediaActivity: EmptyPayload;
	restoreClosedTab: EmptyPayload;
	clearUnpinnedTabs: EmptyPayload;
	loadArchivedTabs: EmptyPayload;
	restoreArchivedTabs: { ids: string[] };
	clearArchivedTabs: EmptyPayload;
	requestTabPreview: { tabId: string };
	navigate: { url: string; typed?: boolean };
	goBack: EmptyPayload;
	goForward: EmptyPayload;
	reload: EmptyPayload;
	showCachedCopy: EmptyPayload;
	reportUnresponsivePage: EmptyPayload;
	stopLoading: EmptyPayload;
	zoomIn: EmptyPayload;
	zoomOut: EmptyPayload;
	zoomReset: EmptyPayload;
	findInPage: { query: string; caseSensitive?: boolean };
	findNext: EmptyPayload;
	findPrevious: EmptyPayload;
	dismissFind: EmptyPayload;
	screenshotPage: { mode: "full" | "viewport" | "region" };
	/** Opens the editor on a copied capture, which it holds from then on. */
	editCapture: { captureId: string };
	/** A copied capture whose pill went: the host drops it. */
	releaseCapture: { captureId: string };
	openPasswordsApp: EmptyPayload;
	translatePage: EmptyPayload;
	showFindBar: EmptyPayload;
	toggleReader: EmptyPayload;
	copyPageURL: EmptyPayload;
	togglePinActiveTab: EmptyPayload;
	duplicateActiveTab: EmptyPayload;
	viewPageSource: EmptyPayload;
	savePageAs: EmptyPayload;
	newSplitView: EmptyPayload;
	newTerminal: EmptyPayload;
	splitTab: { tabId: string; side: SplitDropSide; targetTabId?: string };
	splitURL: { url: string; side: SplitDropSide; targetTabId?: string };
	peekURL: { url: string };
	closeSplitView: EmptyPayload;
	"screenshot.saveDefault": ScreenshotExport & { filename: string };
	"screenshot.saveAs": ScreenshotExport & { filename: string };
	"screenshot.copy": ScreenshotExport;
	"screenshot.cancel": { id: string };
	"tabShare.resolve": {
		requestId: string;
		choice: "tab" | "system" | "cancel";
		tabId?: string;
		// The window or screen's "Share audio too" toggle, sent when the page asked for sound.
		audio?: boolean;
	};
	allowCertificateException: { host: string };
	loadBypassingContentBlocker: EmptyPayload;

	createSpace: {
		name?: string;
		icon?: string;
		color?: string;
		colorMode?: SpaceColorMode;
		isPrivate?: boolean;
		profileId?: string;
		/** Creates this profile with the space, which then uses it (profileId is ignored). */
		newProfileName?: string;
		newProfileColor?: string;
	};
	deleteSpace: { id: string };
	switchSpace: { id: string; transitionId?: string };
	moveTabToSpace: { tabId: string; spaceId: string };
	moveFolderToSpace: { folderId: string; spaceId: string };
	moveSpace: { id: string; toIndex: number };
	updateSpace: {
		id: string;
		name?: string;
		icon?: string;
		color?: string;
		colorMode?: SpaceColorMode;
		profileId?: string;
		archiveAfterHours?: number;
		newProfileName?: string;
		newProfileColor?: string;
	};

	updateTabFolder: { id: string; name: string; color: string };
	deleteTabFolder: { id: string };
	setTabFolderCollapsed: { id: string; collapsed: boolean };
	setTabFolderLock: { id: string; password: string; allowsBiometrics: boolean };
	unlockTabFolder: { id: string; password?: string; method?: "biometrics" | "deviceOwner" };
	lockTabFolder: { id: string };
	beginTabFolderLockSetup: { id: string };
	changeTabFolderPassword: { id: string };
	removeTabFolderLock: { id: string };
	setTabFolderBiometrics: { id: string; allowsBiometrics: boolean; password?: string };
	commitSidebarDrop: BridgeSidebarDropPayload;

	createProfile: { name: string; color?: string };
	/** `moveTo` receives the profile's spaces first, and its default role. */
	deleteProfile: { id: string; moveTo?: string };
	updateProfile: { id: string; name?: string; color?: string };
	getProfileStats: EmptyPayload;

	searchHistory: { query: string };
	searchSuggestions: { query: string; engine: string };
	/** The command bar's top hit to load out of sight; an empty `url` drops it. */
	preloadTopHit: { url: string };
	deleteHistoryEntry: { url: string; query: string };

	omniboxInputStarted: { sessionId: string; query: string };
	omniboxInputChanged: { sessionId: string; query: string };
	omniboxInputEntered: { sessionId: string; query: string; text: string; disposition: string };
	omniboxInputCancelled: { sessionId: string };
	/** The user deleted a `deletable` suggestion: `text` is its description, as in Chrome. */
	omniboxDeleteSuggestion: { query: string; text: string };

	getSettings: EmptyPayload;
	setSetting: { key: string; value: string };
	getFeatureFlags: EmptyPayload;
	setFeatureFlag: { key: string; enabled: boolean };
	resetFeatureFlags: EmptyPayload;
	getSitePermissions: EmptyPayload;
	revokeSitePermission: { id: string };
	setSitePermission: { origin: string; type: string; allow: boolean };
	toggleBlockerAllowlist: { host: string };
	/** `siteData` clears every kind of site data, cookies and cache included, and with an all-time range the site permissions. */
	clearBrowsingData: { kinds: BridgeBrowsingDataKind[]; range: string };
	getBrowsingDataSizes: EmptyPayload;
	getWebsiteData: EmptyPayload;
	getTerminalOptions: EmptyPayload;
	runInTerminal: { command: string; split: boolean };
	terminalCompletions: { query: string };
	revealTerminal: { tabId: string };
	answerTerminal: { tabId: string; text: string };
	restoreClosedTerminal: { index: number };
	getKeepAwakeState: EmptyPayload;
	getAgentActivity: EmptyPayload;
	/** `alwaysAllowSite`: the site whose consequential actions the user always allows from now on. */
	agentControlResponse: { requestId: string; granted: boolean; alwaysAllowSite?: string };
	snoozeKeepAwake: EmptyPayload;
	openLoginItemsSettings: EmptyPayload;
	getRunningApps: EmptyPayload;
	showNextWaitingTerminal: EmptyPayload;
	showChanges: { tabId?: string };
	importTerminalTheme: EmptyPayload;
	connectAgentClient: { client: string };
	getAgentClients: EmptyPayload;
	revokeAgentClient: { name: string };
	getAppNames: { ids: string[] };
	getUpdaterStatus: EmptyPayload;
	checkForUpdates: EmptyPayload;
	installUpdate: EmptyPayload;
	dismissUpdate: EmptyPayload;
	unlockDeveloperTools: EmptyPayload;
	setAutomaticUpdates: { enabled: boolean };
	getShortcuts: EmptyPayload;
	/** Records the next key press for this action; null stops recording. */
	recordShortcut: { id: string | null };
	/** Binds the combo, taking it from the action holding it. */
	setShortcut: { id: string; combo: string };
	resetShortcut: { id: string };
	applyShortcutPreset: { preset: "lilo" | "arc" };
	/** Gives Control-Tab and Control-Shift-Tab to the recent tabs switcher, or to the sidebar's next and previous tab. */
	setControlTabOrder: { order: BridgeControlTabOrder };
	removeWebsiteData: { name: string };
	getZoomLevels: EmptyPayload;
	resetZoomLevel: { host: string };
	getContentBlockerStatus: EmptyPayload;
	updateFilterLists: EmptyPayload;
	getDeviceSetup: EmptyPayload;
	forgetDeviceSetup: EmptyPayload;
	getExtensionDiagnostics: EmptyPayload;
	getStartupMetrics: EmptyPayload;
	clearExtensionDiagnostics: EmptyPayload;
	copyExtensionDiagnostics: EmptyPayload;
	copyDiagnosticsReport: EmptyPayload;
	togglePerfRecording: EmptyPayload;
	forceLifecycleTrim: EmptyPayload;
	getDefaultBrowserStatus: EmptyPayload;
	setDefaultBrowser: EmptyPayload;
	scanImportSources: EmptyPayload;
	runImport: { selections: ImportSelection[] };
	openFullDiskAccessSettings: EmptyPayload;
	closeImport: EmptyPayload;
	getOnboardingState: EmptyPayload;
	getAppIcons: EmptyPayload;
	setOnboardingStep: { step: number };
	completeOnboarding: EmptyPayload;
	dismissDefaultBrowserInvite: EmptyPayload;

	getProcessSnapshot: EmptyPayload;
	getTabMemory: { tabId: string };
	focusProcessTab: { tabId: string; spaceId: string };
	reloadProcessTab: { tabId: string; spaceId: string };
	closeProcessTab: { tabId: string; spaceId: string };
	sleepHiddenTabs: EmptyPayload;
	terminateProcess: { processId: string; confirmed: boolean };

	installExtension: { path: string };
	loadUnpackedExtension: EmptyPayload;
	// `profileId` names a profile the window does not show, picked in Settings > Extensions.
	uninstallExtension: { id: string; profileId?: string };
	enableExtension: { id: string; profileId?: string };
	disableExtension: { id: string; profileId?: string };
	updateExtension: { id: string; profileId?: string };
	checkExtensionUpdates: EmptyPayload;
	setExtensionSiteAccess: { id: string; hosts: string[]; profileId?: string };
	setExtensionPrivateAccess: { id: string; allowed: boolean; profileId?: string };
	setExtensionUserScripts: { id: string; allowed: boolean; profileId?: string };
	setExtensionCommandShortcut: { id: string; command: string; key: string; modifiers: number; profileId?: string };
	/** Answered by `profileExtensionsLoaded`; `live` restores the profile's registry for the full rows. */
	getProfileExtensions: { profileId: string; live: boolean };
	acceptExtensionHostAccessRequest: { id: string };
	getExtensionDebuggers: EmptyPayload;
	/** Detaches every chrome.debugger session of the extension, `id` from `extensionDebuggers`. */
	cancelExtensionDebugging: { id: string };
	openExtensionPopup: { id: string; x: number; y: number; width: number; height: number };
	updateExtensionPopupAnchor: { id: string; x: number; y: number; width: number; height: number };

	/** Request a full-state resync for a space. Sent by the UI when it detects a `stateSeq` gap. */
	requestBrowserStateSync: { spaceId?: string };

	chooseDownloadsFolder: EmptyPayload;
	openDownload: { id: number };
	showDownloadInFinder: { id: number };
	requestDownloadsSnapshot: EmptyPayload;
	pauseDownload: { id: number };
	resumeDownload: { id: number };
	cancelDownload: { id: number };
	eraseDownload: { id: number };
	retryDownload: { id: number };
	removeDownloadFile: { id: number };
	quickLookDownload: { id: number };
	startDownloadDrag: { id: number };
	showDownloadsFolder: EmptyPayload;
	showDownloadContextMenu: {
		id: number;
		x: number;
		y: number;
		width: number;
		height: number;
		state: string;
		fileMissing: boolean;
	};
	showExtensionContextMenu: {
		id: string;
		x: number;
		y: number;
		width: number;
		height: number;
		pinned?: boolean;
		profileId?: string;
	};
}

export interface BridgeEventPayloadMap {
	initialState: BridgeInitialStatePayload;
	screenshotCapturing: EmptyPayload;
	screenshotCaptured: { id: string; url: string; filename: string; truncated?: boolean };
	/** A capture copied; `captureId` can still be opened or saved until its card goes. */
	captureCopied: { captureId: string; thumbURL: string; filename: string };
	screenshotSaved: { path: string };
	screenshotError: { message: string };
	sidebarVisibilityChanged: { visible: boolean; width: number };
	windowChromeStateChanged: { trafficLightsVisible: boolean };
	/** The dominant color of this window's wallpaper and a small JPEG data URL of it; empty when it can't be read. */
	wallpaperColorChanged: { color: string; thumbnail?: string };
	tabLayoutChanged: { position: TabPosition; address: AddressPlacement };
	windowFullscreenChanged: { isFullscreen: boolean };
	windowFocusChanged: { focused: boolean };
	cancelDrag: EmptyPayload;
	openCommandBar: { newTab?: boolean; prefill?: string; selectAll?: boolean };
	toggleCommandBar: { prefill?: string; selectAll?: boolean };
	openHistory: EmptyPayload;
	closeCommandBarAfterNavigation: EmptyPayload;
	openSettings: EmptyPayload;
	openClearBrowsingData: EmptyPayload;
	openShortcuts: EmptyPayload;
	openDesignSystem: EmptyPayload;
	startOnboarding: EmptyPayload;
	openDiagnostics: EmptyPayload;
	openProcessManager: EmptyPayload;
	openDownloads: EmptyPayload;
	openExtensions: EmptyPayload;
	openConfig: EmptyPayload;
	featureFlagsLoaded: { flags: BridgeFeatureFlagSnapshot[] };
	/** `host`: the content blocker allowlist entry for the page; `site`: its registrable domain. */
	pageResponsivenessChanged: { tabId: string; responsive: boolean; host: string; site: string };
	/** Extensions debugging a tab with chrome.debugger, as Chrome's infobar lists them. */
	extensionDebuggers: { debuggers: { id: string; name: string }[] };
	// The selected tab another window shows, or "" when this window shows its own content again.
	// lockedFolderId is set when the selected tab sits in a locked folder.
	contentPlaceholder: { tabId: string; lockedFolderId?: string };
	beginFolderUnlock: { id: string };
	beginFolderLockSetup: { id: string; biometricsAvailable: boolean };
	folderUnlockFailed: { id: string };
	folderPasswordRejected: { id: string };
	trackersBlockedChanged: { count: number };
	toggleNewTab: EmptyPayload;
	toggleFindBar: { query?: string };
	findInPageResult: { query: string; matchFound: boolean };
	contentInteraction: { isMouseDown?: boolean };
	zoomChanged: { level: number };
	blockerAllowlistChanged: { allowlist: string[] };
	defaultBrowserStatusLoaded: { isDefault: boolean; shouldInvite: boolean };
	importSourcesLoaded: { sources: ImportSourceInfo[] };
	importProgress: ImportProgress;
	importFinished: { summary: ImportSummaryItem[] };
	onboardingState: { show: boolean; step: number; usage: string };
	appIconsLoaded: { icons: { id: string; dataURL: string }[] };
	// A space's persisted tab state was unreadable at restore: it was quarantined and the space
	// restored empty. The banner names the space so the user knows what degraded.
	sessionRestoreDegraded: { spaceName: string };

	permissionRequest: BridgePermissionRequestPayload;
	// The request left the native queue unanswered (its tab closed, or it timed out).
	permissionRequestClosed: { requestId: string };
	extensionPermissionRequested: BridgeExtensionPermissionRequestPayload;
	// getDisplayMedia tab-share picker: `origin` is the display host of the requesting page,
	// `shareableTabIds` the tabs native can resolve to a live engine, the requesting tab left out;
	// `suggestedTabIds` a few of them to offer first. `allowsSystem` false (an extension's
	// chrome.desktopCapture offering tabs only) hides "share a screen or window". `audio` is present when the
	// page asked for sound: whether the Mac's sound can be captured, and the toggle's remembered state.
	tabSharePickerRequested: {
		requestId: string;
		origin: string;
		shareableTabIds: string[];
		suggestedTabIds?: string[];
		allowsSystem?: boolean;
		audio?: BridgeTabShareAudio;
	};
	// The requesting tab closed while its picker was open; native already cancelled the pick.
	tabSharePickerDismissed: { requestId: string };
	pipDockChanged: { active: boolean; title?: string };

	browserStateChanged: BridgeBrowserStateChangedPayload;
	browserStatePatch: BridgeBrowserStatePatchPayload;
	// Reply to requestTabPreview. `image` is a JPEG data URL; absent means no preview is
	// available (typically a discarded engine). A terminal sends its screen as text instead.
	tabPreviewReady: { tabId: string; image?: string } & Partial<BridgeTerminalPrompt>;
	// Every started terminal this window may name, sent whenever one changes state.
	terminalActivity: { terminals: BridgeTerminalSummary[] };
	mediaActivity: { tabs: BridgeMediaTab[]; calls: BridgeCallTab[] };
	// Sent when a non-blank tab closes; restoreClosedTab reopens it. A Clear names the tabs it
	// archived instead, for restoreArchivedTabs.
	tabClosedUndoable: { title: string; count?: number; archivedIds?: string[] };
	// Reply to loadArchivedTabs: the current space's archived tabs, newest first.
	archivedTabs: { tabs: BridgeArchivedTab[] };
	powerModeChanged: { constrained: boolean };
	reduceTransparencyChanged: { reduce: boolean };

	spaceCreated: BridgeSpaceSnapshot;
	spaceDeleted: {
		id: string;
		activeSpaceId?: string;
		spaces?: BridgeSpaceSnapshot[];
	};
	spaceUpdated: BridgeSpaceSnapshot;
	spacesReordered: { spaces: BridgeSpaceSnapshot[] };

	profileCreated: BridgeProfileSnapshot;
	profileDeleted: { id: string };
	profileActivated: { id: string };
	profileUpdated: BridgeProfileSnapshot;
	profileStats: { extensionCounts: Record<string, number> };

	historyResults: { query?: string; results: BridgeHistoryResultSnapshot[] };
	searchSuggestions: { query?: string; suggestions: string[] };
	omniboxSuggestions: {
		sessionId: string;
		extensionId: string;
		suggestions: { content: string; description: string; deletable?: boolean }[];
		defaultSuggestion?: string;
	};

	settingsLoaded: { settings: Record<string, string> };
	sitePermissionsLoaded: { permissions: BridgeSitePermissionSnapshot[] };
	extensionDiagnosticsLoaded: {
		entries: BridgeExtensionDiagnosticSnapshot[];
	};
	startupMetricsLoaded: {
		summary: BridgeStartupMetricSummary;
		marks: BridgeStartupMetricMarkSnapshot[];
		traces: BridgeStartupTraceSnapshot[];
		lifecycleDiagnostics?: BridgeTabLifecycleDiagnostics;
		/** Epoch milliseconds the running performance recording started at, or null. */
		perfRecordingStartedAt?: number | null;
	};
	perfRecordingChanged: { startedAt: number | null };
	settingsActionCompleted: BridgeSettingsActionStatusPayload;
	websiteDataLoaded: { sites: BridgeWebsiteDataSnapshot[] };
	browsingDataSizesLoaded: BridgeBrowsingDataSizes;
	terminalOptions: BridgeTerminalOptions;
	terminalCompletionResults: {
		query: string;
		items: BridgeTerminalCompletion[];
		terminals?: BridgeTerminalSummary[];
		closedTerminals?: BridgeClosedTerminal[];
	};
	keepAwakeChanged: BridgeKeepAwakeState;
	agentActivity: {
		clients: BridgeAgentClient[];
		/** One Agents space per profile agents work in. */
		agentsSpaceIds: string[];
		/** The agents' throwaway profile, empty before the first agent. */
		agentsProfileId: string;
		/** Agents spaces with no agent working there and no tab left. */
		hiddenAgentsSpaceIds: string[];
	};
	agentClientsLoaded: BridgeAgentClientsSnapshot;
	appNames: { names: Record<string, string> };
	updaterStatus: BridgeUpdaterStatus;
	/** The downloaded update waiting for a relaunch; null once dismissed. */
	updateReady: { version: string | null };
	shortcutsLoaded: { groups: BridgeShortcutGroup[]; controlTabOrder: BridgeControlTabOrder };
	/** Each bound action's first keys as the menus show them ("⇧⌘T"), by action id ("tab.reopenClosed"). */
	shortcutKeys: { keys: Record<string, string> };
	/** A recorded combo another action holds: `owner` names it, `keys` spells the combo. */
	shortcutConflict: BridgeShortcutConflict;
	/** `profileName` is set when an agent asks to move the Agents space to that profile, `action` when it is about to
	 * click ("click") or submit ("enter") a control labelled `label` that sends, pays, deletes or publishes. */
	agentControlRequested: {
		requestId: string;
		clientName: string;
		/** The program asking to connect, empty for a client already allowed. */
		executable: string;
		profileName: string;
		action: BridgeAgentAction | null;
	};
	runningApps: { apps: BridgeRunningApp[] };
	zoomLevelsLoaded: { levels: BridgeZoomLevelSnapshot[] };
	deviceSetupLoaded: BridgeDeviceSetupSnapshot;
	contentBlockerStatus: BridgeContentBlockerStatus;
	processSnapshotUpdated: BridgeProcessSnapshot;
	tabMemoryUpdated: { tabId: string; bytes: number; cpuPercent?: number };
	splitPanesChanged: { panes: BridgeSplitPaneFrame[] };
	/** Width the extension side panel and its divider take right of the content; 0 when closed. */
	sidePanelWidthChanged: { width: number };
	processManagerActionCompleted: BridgeProcessManagerActionStatusPayload;
	downloadUpdated: BridgeDownloadSnapshot;
	downloadsSnapshot: { items: BridgeDownloadSnapshot[] };
	downloadErased: { id: number };
	// Native ⋯ menu on a download row resolved to a UI action.
	downloadMenuAction: {
		id: number;
		action:
			| "open"
			| "quickLook"
			| "showInFinder"
			| "deleteFile"
			| "removeFromList"
			| "cancel"
			| "retry";
	};
	// `ids` lists every extension in order; `extensions` carries only the rows that changed, and a
	// changed enabled row leaves out an unchanged `iconDataURL`.
	// downloadUiEnabled: false while an extension hid the download UI (chrome.downloads.setUiOptions).
	extensionsChanged: { ids: string[]; extensions: BridgeExtensionSnapshot[]; updateCheck?: BridgeExtensionUpdateCheck; downloadUiEnabled?: boolean };
	// Every row of a profile the window does not show; `live` once they come from its restored registry, else from storage.
	profileExtensionsLoaded: { profileId: string; live: boolean; extensions: BridgeExtensionSnapshot[] };
	// A UI-initiated enable/disable/uninstall/update/store install settled: lets the panel resolve its
	// pending state crisply (success or failure) instead of waiting on a timeout.
	extensionActionCompleted: {
		id: string;
		action: "enable" | "disable" | "uninstall" | "update" | "install";
		success: boolean;
		error?: string;
	};
	// Native ⋯ menu on an extension row resolved to a UI action.
	extensionMenuAction: { id: string; action: "details" | "remove" | "togglePin" };
	hoveredLinkChanged: { href: string };
	commandKeyChanged: { down: boolean };
	// The recent tabs switcher opened on `selected`, moved by one row, and closed: on the selection when `commit`.
	tabSwitcherOpened: { tabs: BridgeRecentTab[]; selected: number };
	tabSwitcherMoved: { by: number };
	tabSwitcherClosed: { commit: boolean };
	crashRecoveryDetected: EmptyPayload;
	editTabFolder: { id: string };
	beginTabEdit: { id: string; homeURL: string };
	openSpaceEditor: { id: string };
	openAddSpaceEditor: EmptyPayload;
	urlCopied: EmptyPayload;
	urlCopyFailed: EmptyPayload;
}

export type BridgeCommandName = keyof BridgeCommandPayloadMap;
export type BridgeEventName = keyof BridgeEventPayloadMap;

export type BridgeEventEnvelope<K extends BridgeEventName = BridgeEventName> = {
	event: K;
} & BridgeEventPayloadMap[K];

export type AnyBridgeEventEnvelope = {
	[K in BridgeEventName]: BridgeEventEnvelope<K>;
}[BridgeEventName];

export type OptionalPayloadCommandName = {
	[K in BridgeCommandName]: EmptyPayload extends BridgeCommandPayloadMap[K]
		? K
		: never;
}[BridgeCommandName];

export type RequiredPayloadCommandName = Exclude<
	BridgeCommandName,
	OptionalPayloadCommandName
>;

/** A terminal theme as previewed in Settings: colors resolved on the current Space. */
export interface BridgeTerminalTheme {
	id: string;
	name: string;
	background: string;
	foreground: string;
	palette: string[];
}

export interface BridgeTerminalOptions {
	themes: BridgeTerminalTheme[];
	/** Installed monospaced font families. */
	fonts: string[];
	/** The font family the user's Ghostty config sets, or empty. */
	ghosttyFont: string;
}

/** Whether a working terminal command keeps the Mac awake, and the root helper's install status. */
export interface BridgeKeepAwakeState {
	keepsAwake: boolean;
	/** Display names of the browser agents among the work keeping the Mac awake. */
	agents: string[];
	/** Terminal tabs whose command keeps the Mac awake. */
	tabIds: string[];
	holdsLidClosed: boolean;
	helperStatus: "unsigned" | "notRegistered" | "requiresApproval" | "enabled" | "notFound";
}

export interface BridgeRunningApp {
	bundleId: string;
	name: string;
}

/** Agent apps installed or naming Lilo in their configuration, and the agents the user let in. */
export interface BridgeAgentClientsSnapshot {
	/** `icon` is a PNG data URL of the app (Terminal's for a command-line tool), null when it is not installed. */
	clients: { id: string; configured: boolean; icon: string | null }[];
	/** `name` is what the agent calls itself; `displayName` is how people know it ("Claude Code"); `client` the
	 * entry of `clients` it is, null for an agent Lilo has no configuration for. */
	allowed: { name: string; displayName: string; lastSeen: number | null; client: string | null }[];
}

export interface BridgeUpdaterStatus {
	version: string;
	/** False in builds that never check for updates (local and debug builds). */
	available: boolean;
	automatic: boolean;
	lastCheck: number | null;
}

/** One menu's actions, keys already spelled with their symbols; `custom` when the user changed them. */
export interface BridgeShortcutGroup {
	title: string;
	items: { id: string; title: string; keys: string[]; custom: boolean }[];
}

export type BridgeControlTabOrder = "recent" | "sidebar";

/** A recent tabs switcher row, current tab first; `leftAt` is when it was last left (ms), 0 when unknown. */
export interface BridgeRecentTab {
	id: string;
	title: string;
	url: string;
	faviconDataURL: string;
	kind: "web" | "terminal" | "changes";
	cwd: string;
	terminalState: string;
	terminalCommand: string;
	spaceName: string;
	leftAt: number;
}

export interface BridgeShortcutConflict {
	id: string;
	combo: string;
	keys: string;
	owner: string;
}

/** A click ("click") or form submission ("enter") an agent is about to make on a control labelled `label`. */
export interface BridgeAgentAction {
	/** For "upload", `label` is the file's path; for "fetch", the request's method and URL. */
	kind: "click" | "enter" | "fetch" | "upload";
	label: string;
	site: string;
	tab: string;
}

/** An AI agent connected over MCP, by the name it gave, and whether a tool call of it runs now. */
export interface BridgeAgentClient {
	name: string;
	busy: boolean;
	/** Tabs it acts on now, or did a moment ago. */
	actingTabIds: string[];
	/** The Agents spaces it works in. */
	spaceIds: string[];
}

export type BridgeMediaAction = "play" | "pause" | "nexttrack" | "previoustrack";
export type BridgeCallAction = "togglemicrophone" | "togglecamera" | "hangup";

/** A tab playing media, or paused from the sidebar's media card. */
export interface BridgeMediaTab {
	id: string;
	spaceId: string;
	title: string;
	faviconDataURL: string;
	playing: boolean;
	muted: boolean;
	/** The page registered Media Session next or previous track handlers. */
	hasTrackControls: boolean;
}

/** A tab capturing the microphone or camera, for the sidebar's call card. */
export interface BridgeCallTab {
	id: string;
	spaceId: string;
	title: string;
	faviconDataURL: string;
	hasMicrophone: boolean;
	microphoneMuted: boolean;
	hasCamera: boolean;
	cameraOff: boolean;
	/** The tab's own sound, muted in Lilo. */
	muted: boolean;
	/** The page registered a Media Session hangup handler. */
	canHangUp: boolean;
	/** The tab the call shares through Lilo's tab share, if it shares one. */
	share?: { token: string; tabId: string; title: string };
}

/** A started terminal of any window or Space, listed after `>`. Times are milliseconds since 1970, 0 when unset. */
export interface BridgeTerminalSummary {
	tabId: string;
	title: string;
	command: string;
	state: string;
	awaitingInputSince: number;
	startedAt: number;
	exitCode: number;
	duration: number;
	gitBranch: string;
	spaceId: string;
	spaceName: string;
}

export interface BridgeArchivedTab {
	id: string;
	url: string;
	title: string;
	/** Milliseconds since 1970. */
	archivedAt: number;
}

/** A closed terminal Cmd+Shift+T or the command bar can reopen; `index` counts closed terminals newest first. */
export interface BridgeClosedTerminal {
	index: number;
	title: string;
	resumeCommand: string;
	gitBranch: string;
	folder: string;
	/** Milliseconds since 1970. */
	closedAt: number;
	hasScreen: boolean;
	spaceName: string;
}

/** The bottom of a terminal's screen; `choices` are the options of a menu it waits on, else empty. */
export interface BridgeTerminalPrompt {
	lines: string[];
	question: string;
	choices: { key: string; label: string }[];
}

/** A shell command offered while typing after `>`: from the user's history, or a program on PATH. */
export interface BridgeTerminalCompletion {
	command: string;
	source: "history" | "command";
}
