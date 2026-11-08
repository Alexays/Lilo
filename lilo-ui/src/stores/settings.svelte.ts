import { on } from "../lib/bridge";
import { featureFlagsActions, settingsActions } from "../lib/bridge/actions";
import type {
	BridgeAgentClientsSnapshot,
	BridgeBrowsingDataSizes,
	BridgeContentBlockerStatus,
	BridgeControlTabOrder,
	BridgeDeviceSetupSnapshot,
	BridgeFeatureFlagSnapshot,
	BridgeSettingsActionStatusPayload,
	BridgeShortcutConflict,
	BridgeShortcutGroup,
	BridgeSitePermissionSnapshot,
	BridgeTerminalOptions,
	BridgeUpdaterStatus,
	BridgeWebsiteDataSnapshot,
	BridgeZoomLevelSnapshot,
} from "../lib/bridge/protocol";
import { setLocale } from "../lib/i18n/state.svelte";
import { isSupportedLocale } from "../lib/i18n/translate";

// Settings values arrive as one string map; each surface reads the keys it owns.
const _values = $state<Record<string, string>>({});
let _defaultBrowser = $state({ isDefault: false, shouldInvite: false });
let _sitePermissions = $state.raw<BridgeSitePermissionSnapshot[]>([]);
let _websiteData = $state.raw<BridgeWebsiteDataSnapshot[]>([]);
let _browsingDataSizes = $state.raw<BridgeBrowsingDataSizes | null>(null);
let _zoomLevels = $state.raw<BridgeZoomLevelSnapshot[]>([]);
// Agent apps whose connect is still writing their configuration.
let _connectingAgentClients = $state.raw<string[]>([]);
let _featureFlags = $state.raw<BridgeFeatureFlagSnapshot[]>([]);
let _deviceSetup = $state.raw<BridgeDeviceSetupSnapshot>({ label: "" });
let _blockerStatus = $state.raw<BridgeContentBlockerStatus | null>(null);
let _terminalOptions = $state.raw<BridgeTerminalOptions | null>(null);
let _status = $state<BridgeSettingsActionStatusPayload | null>(null);
let _appIcons = $state.raw<{ id: string; dataURL: string; seasonalDataURL?: string }[]>([]);
let _agentClients = $state.raw<BridgeAgentClientsSnapshot>({ clients: [], allowed: [] });
let _updater = $state.raw<BridgeUpdaterStatus | null>(null);
let _readyUpdate = $state<string | null>(null);
let _restartingForUpdate = $state(false);
let _shortcuts = $state.raw<BridgeShortcutGroup[]>([]);
let _controlTabOrder = $state<BridgeControlTabOrder>("recent");
let _recordingShortcut = $state<string | null>(null);
let _shortcutConflict = $state.raw<BridgeShortcutConflict | null>(null);
let statusTimer: ReturnType<typeof setTimeout> | null = null;

export function initSettingsStore(): void {
	// Every setting change republishes the whole map: merged key by key, only the readers of a changed key re-run.
	on("settingsLoaded", (data) => {
		const next = data.settings ?? {};
		for (const key in _values) if (!(key in next)) delete _values[key];
		for (const key in next) if (_values[key] !== next[key]) _values[key] = next[key];
		const locale = _values["locale"];
		if (locale && isSupportedLocale(locale)) void setLocale(locale);
	});
	on("tabListMenuAction", ({ action, host }) => {
		const never = getSetting("sidebarNeverStack", "").split(",").filter(Boolean);
		if (action === "toggleStackTabs") setSetting("sidebarStackTabs", String(getSetting("sidebarStackTabs", "true") === "false"));
		else if (action === "toggleGroupByType") setSetting("sidebarGroupByType", String(getSetting("sidebarGroupByType", "false") !== "true"));
		else if (action === "toggleGroupByProject") setSetting("sidebarGroupByProject", String(getSetting("sidebarGroupByProject", "false") !== "true"));
		else if (action === "neverStack" && !never.includes(host)) setSetting("sidebarNeverStack", [...never, host].join(","));
		else if (action === "stackAgain") setSetting("sidebarNeverStack", never.filter((entry) => entry !== host).join(","));
		else if (action === "stackEverySite") setSetting("sidebarNeverStack", "");
	});
	on("defaultBrowserStatusLoaded", (data) => {
		_defaultBrowser = data;
	});
	on("sitePermissionsLoaded", (data) => {
		_sitePermissions = data.permissions ?? [];
	});
	on("websiteDataLoaded", (data) => {
		_websiteData = data.sites ?? [];
	});
	on("browsingDataSizesLoaded", (data) => {
		_browsingDataSizes = data;
	});
	on("zoomLevelsLoaded", (data) => {
		_zoomLevels = data.levels ?? [];
	});
	on("featureFlagsLoaded", (data) => {
		_featureFlags = data.flags ?? [];
	});
	on("deviceSetupLoaded", (data) => {
		_deviceSetup = data;
	});
	on("contentBlockerStatus", (data) => {
		_blockerStatus = data;
	});
	on("appIconsLoaded", (data) => {
		_appIcons = data.icons;
	});
	on("terminalOptions", (data) => {
		_terminalOptions = data;
	});
	on("agentClientsLoaded", (data) => {
		_agentClients = data;
	});
	on("updaterStatus", (data) => {
		_updater = data;
	});
	on("updateReady", (data) => {
		_readyUpdate = data.version;
		// Lilo is still running: a cancelled quit resends the update, which can be restarted again.
		_restartingForUpdate = false;
		// The update shows the chosen app icon, which only reaches the chrome with the settings.
		if (data.version && _appIcons.length === 0) {
			settingsActions.load();
			settingsActions.loadAppIcons();
		}
	});
	on("shortcutsLoaded", (data) => {
		_shortcuts = data.groups;
		_controlTabOrder = data.controlTabOrder;
		_recordingShortcut = null;
		_shortcutConflict = null;
	});
	on("shortcutConflict", (data) => {
		_recordingShortcut = null;
		_shortcutConflict = data;
	});
	on("settingsActionCompleted", (data) => {
		if (data.action === "connectAgentClient") _connectingAgentClients = [];
		_status = data;
		if (statusTimer) clearTimeout(statusTimer);
		statusTimer = setTimeout(() => {
			_status = null;
			statusTimer = null;
		}, 4000);
	});
}

/** Refreshes what every settings page shows; runs each time it opens. Costly lists load with the pages that show them. */
export function loadSettingsSurface(): void {
	settingsActions.load();
	settingsActions.loadDefaultBrowserStatus();
	settingsActions.loadSitePermissions();
	settingsActions.loadZoomLevels();
	featureFlagsActions.load();
	settingsActions.loadDeviceSetup();
	settingsActions.loadContentBlockerStatus();
	settingsActions.loadAgentClients();
	settingsActions.loadUpdaterStatus();
}

export function getSetting(key: string, fallback: string): string {
	return _values[key] ?? fallback;
}

export function setSetting(key: string, value: string): void {
	_values[key] = value;
	settingsActions.set(key, value);
}

let _hiddenElementsSetting: string | undefined;
let _hiddenElements: Record<string, string[]> = {};

/** The elements the user hid: selectors by host, without "www.". Parsed again only when its setting changes. */
export function getHiddenElements(): Record<string, string[]> {
	const setting = _values["hiddenElements"];
	if (setting !== _hiddenElementsSetting) {
		_hiddenElementsSetting = setting;
		try {
			const parsed: unknown = JSON.parse(setting ?? "{}");
			_hiddenElements = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, string[]>) : {};
		} catch {
			_hiddenElements = {};
		}
	}
	return _hiddenElements;
}

/** Keeps `selectors` hidden on `host`; none shows every element there again. Pages follow from their next load. */
export function setHiddenElements(host: string, selectors: string[]): void {
	const next = { ...getHiddenElements() };
	if (selectors.length > 0) next[host] = selectors;
	else delete next[host];
	setSetting("hiddenElements", JSON.stringify(next));
}

export function getDefaultBrowserStatus(): { isDefault: boolean; shouldInvite: boolean } {
	return _defaultBrowser;
}

export function getSitePermissions(): BridgeSitePermissionSnapshot[] {
	return _sitePermissions;
}

export function getWebsiteData(): BridgeWebsiteDataSnapshot[] {
	return _websiteData;
}

export function getZoomLevels(): BridgeZoomLevelSnapshot[] {
	return _zoomLevels;
}

export function getFeatureFlags(): BridgeFeatureFlagSnapshot[] {
	return _featureFlags;
}

export function getContentBlockerStatus(): BridgeContentBlockerStatus | null {
	return _blockerStatus;
}

export function getDeviceSetup(): BridgeDeviceSetupSnapshot {
	return _deviceSetup;
}

/** Terminal themes with their colors on the current Space, fonts, and what Ghostty's config offers. */
export function getTerminalOptions(): BridgeTerminalOptions | null {
	return _terminalOptions;
}

export function getSettingsStatus(): BridgeSettingsActionStatusPayload | null {
	return _status;
}

/** Null until the clear-data page has asked for them. */
export function getBrowsingDataSizes(): BridgeBrowsingDataSizes | null {
	return _browsingDataSizes;
}

export function getAppIcons(): { id: string; dataURL: string; seasonalDataURL?: string }[] {
	return _appIcons;
}

/** The preview of the app icon chosen in the settings, once the previews are loaded. */
export function getChosenAppIcon(): string | undefined {
	return _appIcons.find((icon) => icon.id === getSetting("appIcon", "classic"))?.dataURL;
}

export function connectAgentClient(client: string): void {
	if (_connectingAgentClients.includes(client)) return;
	_connectingAgentClients = [..._connectingAgentClients, client];
	settingsActions.connectAgentClient(client);
}

export function isConnectingAgentClient(client: string): boolean {
	return _connectingAgentClients.includes(client);
}

export function getAgentClientsSnapshot(): BridgeAgentClientsSnapshot {
	return _agentClients;
}

export function getUpdaterStatus(): BridgeUpdaterStatus | null {
	return _updater;
}

/** The version of the downloaded update waiting for a relaunch, null when none is shown. */
export function getReadyUpdate(): string | null {
	return _readyUpdate;
}

/** True from the Restart click until Lilo quits or the quit is cancelled. */
export function isRestartingForUpdate(): boolean {
	return _restartingForUpdate;
}

export function restartForUpdate(): void {
	if (_restartingForUpdate) return;
	_restartingForUpdate = true;
	settingsActions.installUpdate();
}

/** The menus' keyboard shortcuts, loaded when their page opens. */
export function getShortcuts(): BridgeShortcutGroup[] {
	return _shortcuts;
}

/** Whether Control-Tab walks tabs by last use or in sidebar order, as the shortcuts bind it. */
export function getControlTabOrder(): BridgeControlTabOrder {
	return _controlTabOrder;
}

/** The action whose next key press Lilo records, if any. */
export function getRecordingShortcut(): string | null {
	return _recordingShortcut;
}

/** A recorded combo another action holds, waiting for Replace or Cancel. */
export function getShortcutConflict(): BridgeShortcutConflict | null {
	return _shortcutConflict;
}

/** Starts recording `id` (null stops); the native side ends it with the next key press. */
export function recordShortcut(id: string | null): void {
	_recordingShortcut = id;
	_shortcutConflict = null;
	settingsActions.recordShortcut(id);
}

export function dismissShortcutConflict(): void {
	_shortcutConflict = null;
}
