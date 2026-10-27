import { postMessage as emit, type BridgeCommandPayloadMap } from "./index";
import type {
	BridgeCommandName,
	BridgeControlTabOrder,
	BridgeMediaAction,
	ImportSelection,
	OptionalPayloadCommandName,
	ScreenshotExport,
	SplitDropSide,
} from "./protocol";

type IdCommandName = {
	[K in BridgeCommandName]: BridgeCommandPayloadMap[K] extends { id: string }
		? { id: string } extends BridgeCommandPayloadMap[K]
			? K
			: never
		: never;
}[BridgeCommandName];

const emitEmpty = (action: OptionalPayloadCommandName) => () => emit(action);
const emitId = (action: IdCommandName) => (id: string) => emit(action, { id });

export const chromeActions = {
	// `at` is the chrome's own clock, so the host dates the mark when it happened, not when it got it.
	startupMark: (event: string): void =>
		emit("startupMark", { event, at: performance.timeOrigin + performance.now() }),
	markVisualReady: (at: number): void => emit("chromeVisualReady", { at }),
	initialStateApplied: emitEmpty("initialStateApplied"),
	maximizeWindow: emitEmpty("maximizeWindow"),
	startWindowDrag: emitEmpty("startWindowDrag"),
	toggleSidebar: emitEmpty("toggleSidebar"),
	setSidebarCollapseLocked: (locked: boolean): void =>
		emit("setSidebarCollapseLocked", { locked }),
	registerInteractiveZones: (
		zones: BridgeCommandPayloadMap["registerInteractiveZones"]["zones"],
	): void => emit("registerInteractiveZones", { zones }),
	removeInteractiveZone: emitId("removeInteractiveZone"),
	updateWindowBackground: (color: string): void =>
		emit("updateWindowBackground", { color }),
	setWallpaperColorWatch: (enabled: boolean): void =>
		emit("setWallpaperColorWatch", { enabled }),
	sidebarResized: (width: number): void => emit("sidebarResized", { width }),
	sidebarOverlayChanged: (visible: boolean): void =>
		emit("sidebarOverlayChanged", { visible }),
	permissionResponse: (requestId: string, granted: boolean): void =>
		emit("permissionResponse", { requestId, granted }),
	dismissPermissionRequest: (requestId: string): void =>
		emit("permissionResponse", { requestId, granted: false, remember: false }),
	showTabSecurityInfo: emitEmpty("showTabSecurityInfo"),
	showBackHistoryMenu: (
		payload: BridgeCommandPayloadMap["showBackHistoryMenu"],
	): void => emit("showBackHistoryMenu", payload),
	showForwardHistoryMenu: (
		payload: BridgeCommandPayloadMap["showForwardHistoryMenu"],
	): void => emit("showForwardHistoryMenu", payload),
	showSidebarContextMenu: (
		payload: BridgeCommandPayloadMap["showSidebarContextMenu"],
	): void => emit("showSidebarContextMenu", payload),
	traceSpaceSwipe: (
		payload: BridgeCommandPayloadMap["traceSpaceSwipe"],
	): void => emit("traceSpaceSwipe", payload),
	traceSpaceDnd: (
		payload: BridgeCommandPayloadMap["traceSpaceDnd"],
	): void => emit("traceSpaceDnd", payload),
};

export const tabActions = {
	create: (url?: string, typed?: boolean): void =>
		url ? emit("createTab", { url, typed }) : emit("createTab"),
	close: emitId("closeTab"),
	switchTo: emitId("switchTab"),
	switchToRecent: emitId("switchToRecentTab"),
	claim: emitId("claimTab"),
	moveToNewWindow: (id: string, screenX: number, screenY: number): void =>
		emit("moveTabToNewWindow", { id, screenX, screenY }),
	unpin: emitId("unpinTab"),
	setBookmarked: (id: string, bookmarked: boolean): void =>
		emit(bookmarked ? "bookmarkTab" : "unbookmarkTab", { id }),
	rename: (id: string, title: string): void => emit("renameTab", { id, title }),
	setHomeURL: (id: string, url: string): void => emit("setTabHomeURL", { id, url }),
	returnHome: emitId("returnTabHome"),
	setMuted: (id: string, muted: boolean): void =>
		emit(muted ? "muteTab" : "unmuteTab", { id }),
	setMicrophoneMuted: (id: string, muted: boolean): void =>
		emit(muted ? "muteTabMicrophone" : "unmuteTabMicrophone", { id }),
	showContextMenu: (id: string, x: number, y: number, width: number, height: number): void =>
		emit("showTabContextMenu", { id, x, y, width, height }),
	navigate: (url: string, typed?: boolean): void => emit("navigate", { url, typed }),
	goBack: emitEmpty("goBack"),
	goForward: emitEmpty("goForward"),
	reload: emitEmpty("reload"),
	showCachedCopy: emitEmpty("showCachedCopy"),
	reportUnresponsivePage: emitEmpty("reportUnresponsivePage"),
	stopLoading: emitEmpty("stopLoading"),
	zoomIn: emitEmpty("zoomIn"),
	zoomOut: emitEmpty("zoomOut"),
	zoomReset: emitEmpty("zoomReset"),
	screenshotPage: (mode: "full" | "viewport" | "region"): void => emit("screenshotPage", { mode }),
	openPasswordsApp: emitEmpty("openPasswordsApp"),
	translatePage: emitEmpty("translatePage"),
	showFindBar: emitEmpty("showFindBar"),
	toggleReader: emitEmpty("toggleReader"),
	copyPageURL: emitEmpty("copyPageURL"),
	togglePinActive: emitEmpty("togglePinActiveTab"),
	duplicateActive: emitEmpty("duplicateActiveTab"),
	viewPageSource: emitEmpty("viewPageSource"),
	savePageAs: emitEmpty("savePageAs"),
	newSplitView: emitEmpty("newSplitView"),
	newTerminal: emitEmpty("newTerminal"),
	splitTab: (tabId: string, side: SplitDropSide, targetTabId?: string): void =>
		emit("splitTab", { tabId, side, targetTabId }),
	splitURL: (url: string, side: SplitDropSide, targetTabId?: string): void =>
		emit("splitURL", { url, side, targetTabId }),
	/** Opens `url` in a Peek over the active tab. */
	peekURL: (url: string): void => emit("peekURL", { url }),
	closeSplitView: emitEmpty("closeSplitView"),
	restoreClosed: emitEmpty("restoreClosedTab"),
	clearUnpinned: emitEmpty("clearUnpinnedTabs"),
	loadArchived: emitEmpty("loadArchivedTabs"),
	restoreArchived: (ids: string[]): void => emit("restoreArchivedTabs", { ids }),
	clearArchived: emitEmpty("clearArchivedTabs"),
	requestPreview: (tabId: string): void => emit("requestTabPreview", { tabId }),
	findInPage: (query: string, options: { caseSensitive?: boolean } = {}): void =>
		emit("findInPage", { query, ...options }),
	findNext: emitEmpty("findNext"),
	findPrevious: emitEmpty("findPrevious"),
	dismissFind: emitEmpty("dismissFind"),
};

export const screenshotActions = {
	saveDefault: (capture: ScreenshotExport, filename: string): void =>
		emit("screenshot.saveDefault", { ...capture, filename }),
	saveAs: (capture: ScreenshotExport, filename: string): void =>
		emit("screenshot.saveAs", { ...capture, filename }),
	copy: (capture: ScreenshotExport): void => emit("screenshot.copy", capture),
	cancel: (id: string): void => emit("screenshot.cancel", { id }),
	editCopied: (captureId: string): void => emit("editCapture", { captureId }),
	releaseCopied: (captureId: string): void => emit("releaseCapture", { captureId }),
};

export const tabShareActions = {
	resolve: (payload: BridgeCommandPayloadMap["tabShare.resolve"]): void =>
		emit("tabShare.resolve", payload),
};

export const spaceActions = {
	create: (payload: BridgeCommandPayloadMap["createSpace"]): void =>
		emit("createSpace", payload),
	update: (payload: BridgeCommandPayloadMap["updateSpace"]): void =>
		emit("updateSpace", payload),
	delete: emitId("deleteSpace"),
	moveTabToSpace: (tabId: string, spaceId: string): void =>
		emit("moveTabToSpace", { tabId, spaceId }),
	moveFolderToSpace: (folderId: string, spaceId: string): void =>
		emit("moveFolderToSpace", { folderId, spaceId }),
	move: (id: string, toIndex: number): void =>
		emit("moveSpace", { id, toIndex }),
	switchTo: (id: string, transitionId?: string): void =>
		emit("switchSpace", { id, transitionId }),
};

export const folderActions = {
	update: (payload: BridgeCommandPayloadMap["updateTabFolder"]): void =>
		emit("updateTabFolder", payload),
	delete: emitId("deleteTabFolder"),
	showContextMenu: (id: string, x: number, y: number, width: number, height: number): void =>
		emit("showFolderContextMenu", { id, x, y, width, height }),
	setCollapsed: (id: string, collapsed: boolean): void =>
		emit("setTabFolderCollapsed", { id, collapsed }),
	setLock: (id: string, password: string, allowsBiometrics: boolean): void =>
		emit("setTabFolderLock", { id, password, allowsBiometrics }),
	unlockWithPassword: (id: string, password: string): void =>
		emit("unlockTabFolder", { id, password }),
	unlockWith: (id: string, method: "biometrics" | "deviceOwner"): void =>
		emit("unlockTabFolder", { id, method }),
	lock: emitId("lockTabFolder"),
	beginLockSetup: emitId("beginTabFolderLockSetup"),
	changePassword: emitId("changeTabFolderPassword"),
	removeLock: emitId("removeTabFolderLock"),
	setBiometrics: (id: string, allowsBiometrics: boolean, password?: string): void =>
		emit("setTabFolderBiometrics", { id, allowsBiometrics, password }),
};

export const sidebarActions = {
	commitDrop: (payload: BridgeCommandPayloadMap["commitSidebarDrop"]): void =>
		emit("commitSidebarDrop", payload),
};

export const profileActions = {
	create: (name: string, color?: string): void => emit("createProfile", { name, color }),
	update: (payload: BridgeCommandPayloadMap["updateProfile"]): void =>
		emit("updateProfile", payload),
	delete: (id: string, moveTo?: string): void => emit("deleteProfile", { id, moveTo }),
	loadStats: emitEmpty("getProfileStats"),
};

export const settingsActions = {
	load: emitEmpty("getSettings"),
	set: (key: string, value: string): void => emit("setSetting", { key, value }),
	loadSitePermissions: emitEmpty("getSitePermissions"),
	revokeSitePermission: emitId("revokeSitePermission"),
	setSitePermission: (origin: string, type: string, allow: boolean): void =>
		emit("setSitePermission", { origin, type, allow }),
	toggleBlockerAllowlist: (host: string): void => emit("toggleBlockerAllowlist", { host }),
	clearHistory: (range = "all"): void => emit("clearHistory", { range }),
	clearCookies: (range = "all"): void => emit("clearCookies", { range }),
	clearCache: (range = "all"): void => emit("clearCache", { range }),
	clearSiteData: (range = "all"): void => emit("clearSiteData", { range }),
	loadWebsiteData: emitEmpty("getWebsiteData"),
	loadTerminalOptions: emitEmpty("getTerminalOptions"),
	importTerminalTheme: emitEmpty("importTerminalTheme"),
	connectAgentClient: (client: string): void => emit("connectAgentClient", { client }),
	loadAgentClients: emitEmpty("getAgentClients"),
	revokeAgentClient: (name: string): void => emit("revokeAgentClient", { name }),
	loadUpdaterStatus: emitEmpty("getUpdaterStatus"),
	checkForUpdates: emitEmpty("checkForUpdates"),
	installUpdate: emitEmpty("installUpdate"),
	dismissUpdate: emitEmpty("dismissUpdate"),
	unlockDeveloperTools: emitEmpty("unlockDeveloperTools"),
	setAutomaticUpdates: (enabled: boolean): void => emit("setAutomaticUpdates", { enabled }),
	loadShortcuts: emitEmpty("getShortcuts"),
	recordShortcut: (id: string | null): void => emit("recordShortcut", { id }),
	setShortcut: (id: string, combo: string): void => emit("setShortcut", { id, combo }),
	resetShortcut: (id: string): void => emit("resetShortcut", { id }),
	applyShortcutPreset: (preset: "lilo" | "arc"): void => emit("applyShortcutPreset", { preset }),
	setControlTabOrder: (order: BridgeControlTabOrder): void => emit("setControlTabOrder", { order }),
	removeWebsiteData: (name: string): void => emit("removeWebsiteData", { name }),
	loadZoomLevels: emitEmpty("getZoomLevels"),
	resetZoomLevel: (host: string): void => emit("resetZoomLevel", { host }),
	loadContentBlockerStatus: emitEmpty("getContentBlockerStatus"),
	updateFilterLists: emitEmpty("updateFilterLists"),
	loadDeviceSetup: emitEmpty("getDeviceSetup"),
	forgetDeviceSetup: emitEmpty("forgetDeviceSetup"),
	loadExtensionDiagnostics: emitEmpty("getExtensionDiagnostics"),
	loadStartupMetrics: emitEmpty("getStartupMetrics"),
	clearExtensionDiagnostics: emitEmpty("clearExtensionDiagnostics"),
	copyExtensionDiagnostics: emitEmpty("copyExtensionDiagnostics"),
	copyDiagnosticsReport: emitEmpty("copyDiagnosticsReport"),
	togglePerfRecording: emitEmpty("togglePerfRecording"),
	forceLifecycleTrim: emitEmpty("forceLifecycleTrim"),
	chooseDownloadsFolder: emitEmpty("chooseDownloadsFolder"),
	loadDefaultBrowserStatus: emitEmpty("getDefaultBrowserStatus"),
	loadAppIcons: emitEmpty("getAppIcons"),
	setDefaultBrowser: emitEmpty("setDefaultBrowser"),
	dismissDefaultBrowserInvite: emitEmpty("dismissDefaultBrowserInvite"),
};

export const importActions = {
	scan: emitEmpty("scanImportSources"),
	run: (selections: ImportSelection[]): void => emit("runImport", { selections }),
	openFullDiskAccessSettings: emitEmpty("openFullDiskAccessSettings"),
	close: emitEmpty("closeImport"),
};

export const onboardingActions = {
	load: emitEmpty("getOnboardingState"),
	setStep: (step: number): void => emit("setOnboardingStep", { step }),
	complete: emitEmpty("completeOnboarding"),
};

export const featureFlagsActions = {
	load: emitEmpty("getFeatureFlags"),
	setFlag: (key: string, enabled: boolean): void =>
		emit("setFeatureFlag", { key, enabled }),
	resetAll: emitEmpty("resetFeatureFlags"),
};

export const processManagerActions = {
	load: emitEmpty("getProcessSnapshot"),
	loadTabMemory: (tabId: string): void => emit("getTabMemory", { tabId }),
	focusTab: (tabId: string, spaceId: string): void =>
		emit("focusProcessTab", { tabId, spaceId }),
	reloadTab: (tabId: string, spaceId: string): void =>
		emit("reloadProcessTab", { tabId, spaceId }),
	closeTab: (tabId: string, spaceId: string): void =>
		emit("closeProcessTab", { tabId, spaceId }),
	terminateProcess: (
		payload: BridgeCommandPayloadMap["terminateProcess"],
	): void => emit("terminateProcess", payload),
	sleepHiddenTabs: emitEmpty("sleepHiddenTabs"),
};

export const searchActions = {
	loadRecentHistory: (): void => emit("getRecentHistory", {}),
	searchHistory: (query: string): void => emit("searchHistory", { query }),
	deleteHistory: (url: string, query: string): void =>
		emit("deleteHistoryEntry", { url, query }),
	searchSuggestions: (query: string, engine: string): void =>
		emit("searchSuggestions", { query, engine }),
};

export const terminalActions = {
	/** Opens a terminal tab running `command`; `split` puts it next to the current page. */
	run: (command: string, split: boolean): void => emit("runInTerminal", { command, split }),
	complete: (query: string): void => emit("terminalCompletions", { query }),
	reveal: (tabId: string): void => emit("revealTerminal", { tabId }),
	/** Types `text` into the terminal, as an answer to what it waits on. */
	answer: (tabId: string, text: string): void => emit("answerTerminal", { tabId, text }),
	/** Reopens the `index`-th newest closed terminal, with the screen it kept. */
	restoreClosed: (index: number): void => emit("restoreClosedTerminal", { index }),
	showNextWaiting: emitEmpty("showNextWaitingTerminal"),
	/** Opens the Changes peek over the terminal `tabId`, else over the active terminal. */
	showChanges: (tabId?: string): void => (tabId ? emit("showChanges", { tabId }) : emit("showChanges")),
};

export const mediaActions = {
	load: emitEmpty("getMediaActivity"),
	control: (id: string, action: BridgeMediaAction): void => emit("controlMedia", { id, action }),
};

export const agentActions = {
	load: emitEmpty("getAgentActivity"),
	respond: (requestId: string, granted: boolean, alwaysAllowSite?: string): void =>
		emit("agentControlResponse", alwaysAllowSite ? { requestId, granted, alwaysAllowSite } : { requestId, granted }),
};

export const keepAwakeActions = {
	load: emitEmpty("getKeepAwakeState"),
	snooze: emitEmpty("snoozeKeepAwake"),
	openLoginItems: emitEmpty("openLoginItemsSettings"),
	loadRunningApps: emitEmpty("getRunningApps"),
	loadAppNames: (ids: string[]): void => emit("getAppNames", { ids }),
};

export const omniboxActions = {
	inputStarted: (sessionId: string, query: string): void =>
		emit("omniboxInputStarted", { sessionId, query }),
	inputChanged: (sessionId: string, query: string): void =>
		emit("omniboxInputChanged", { sessionId, query }),
	inputEntered: (sessionId: string, query: string, text: string, disposition: string): void =>
		emit("omniboxInputEntered", { sessionId, query, text, disposition }),
	inputCancelled: (sessionId: string): void =>
		emit("omniboxInputCancelled", { sessionId }),
	deleteSuggestion: (query: string, text: string): void =>
		emit("omniboxDeleteSuggestion", { query, text }),
};

export const downloadActions = {
	open: (id: number): void => emit("openDownload", { id }),
	showInFinder: (id: number): void => emit("showDownloadInFinder", { id }),
	pause: (id: number): void => emit("pauseDownload", { id }),
	resume: (id: number): void => emit("resumeDownload", { id }),
	cancel: (id: number): void => emit("cancelDownload", { id }),
	erase: (id: number): void => emit("eraseDownload", { id }),
	retry: (id: number): void => emit("retryDownload", { id }),
	removeFile: (id: number): void => emit("removeDownloadFile", { id }),
	requestSnapshot: (): void => emit("requestDownloadsSnapshot", {}),
	quickLook: (id: number): void => emit("quickLookDownload", { id }),
	startDrag: (id: number): void => emit("startDownloadDrag", { id }),
	showFolder: (): void => emit("showDownloadsFolder", {}),
	showContextMenu: (
		id: number,
		x: number,
		y: number,
		width: number,
		height: number,
		state: string,
		fileMissing: boolean,
	): void =>
		emit("showDownloadContextMenu", { id, x, y, width, height, state, fileMissing }),
};

export const extensionActions = {
	// `profileId` is set for a profile the window does not show.
	enable: (id: string, profileId?: string): void => emit("enableExtension", { id, profileId }),
	disable: (id: string, profileId?: string): void => emit("disableExtension", { id, profileId }),
	uninstall: (id: string, profileId?: string): void => emit("uninstallExtension", { id, profileId }),
	install: (path: string): void => emit("installExtension", { path }),
	setSiteAccess: (id: string, hosts: string[], profileId?: string): void =>
		emit("setExtensionSiteAccess", { id, hosts, profileId }),
	setPrivateAccess: (id: string, allowed: boolean, profileId?: string): void =>
		emit("setExtensionPrivateAccess", { id, allowed, profileId }),
	setUserScripts: (id: string, allowed: boolean, profileId?: string): void =>
		emit("setExtensionUserScripts", { id, allowed, profileId }),
	setCommandShortcut: (id: string, command: string, key: string, modifiers: number, profileId?: string): void =>
		emit("setExtensionCommandShortcut", { id, command, key, modifiers, profileId }),
	loadProfile: (profileId: string, live: boolean): void => emit("getProfileExtensions", { profileId, live }),
	acceptHostAccessRequest: emitId("acceptExtensionHostAccessRequest"),
	loadDebuggers: emitEmpty("getExtensionDebuggers"),
	cancelDebugging: emitId("cancelExtensionDebugging"),
	update: (id: string, profileId?: string): void => emit("updateExtension", { id, profileId }),
	checkUpdates: emitEmpty("checkExtensionUpdates"),
	loadUnpacked: emitEmpty("loadUnpackedExtension"),
	openPopup: (
		id: string,
		x: number,
		y: number,
		width: number,
		height: number,
	): void => emit("openExtensionPopup", { id, x, y, width, height }),
	// `pinned` adds the address-bar pin item; the settings list leaves it out.
	showContextMenu: (
		id: string,
		x: number,
		y: number,
		width: number,
		height: number,
		pinned?: boolean,
		profileId?: string,
	): void =>
		emit("showExtensionContextMenu", { id, x, y, width, height, pinned, profileId }),
	updatePopupAnchor: (
		id: string,
		x: number,
		y: number,
		width: number,
		height: number,
	): void => emit("updateExtensionPopupAnchor", { id, x, y, width, height }),
	permissionResponse: (requestId: string, granted: boolean): void =>
		emit("extensionPermissionResponse", { requestId, granted }),
};
