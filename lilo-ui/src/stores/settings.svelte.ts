import { on } from "../lib/bridge";
import { featureFlagsActions, settingsActions } from "../lib/bridge/actions";
import type {
	BridgeAgentClientsSnapshot,
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
let _values = $state<Record<string, string>>({});
let _defaultBrowser = $state({ isDefault: false, shouldInvite: false });
let _sitePermissions = $state.raw<BridgeSitePermissionSnapshot[]>([]);
let _websiteData = $state.raw<BridgeWebsiteDataSnapshot[]>([]);
let _zoomLevels = $state.raw<BridgeZoomLevelSnapshot[]>([]);
// Agent apps whose connect is still writing their configuration.
let _connectingAgentClients = $state.raw<string[]>([]);
let _featureFlags = $state.raw<BridgeFeatureFlagSnapshot[]>([]);
let _deviceSetup = $state.raw<BridgeDeviceSetupSnapshot>({ label: "" });
let _blockerStatus = $state.raw<BridgeContentBlockerStatus | null>(null);
let _terminalOptions = $state.raw<BridgeTerminalOptions | null>(null);
let _status = $state<BridgeSettingsActionStatusPayload | null>(null);
let _clearDataSheetOpen = $state(false);
let _appIcons = $state.raw<{ id: string; dataURL: string }[]>([]);
let _agentClients = $state.raw<BridgeAgentClientsSnapshot>({ clients: [], allowed: [] });
let _updater = $state.raw<BridgeUpdaterStatus | null>(null);
let _readyUpdate = $state<string | null>(null);
let _shortcuts = $state.raw<BridgeShortcutGroup[]>([]);
let _controlTabOrder = $state<BridgeControlTabOrder>("recent");
let _recordingShortcut = $state<string | null>(null);
let _shortcutConflict = $state.raw<BridgeShortcutConflict | null>(null);
let statusTimer: ReturnType<typeof setTimeout> | null = null;

export function initSettingsStore(): void {
	on("settingsLoaded", (data) => {
		_values = data.settings ?? {};
		const locale = _values["locale"];
		if (locale && isSupportedLocale(locale)) void setLocale(locale);
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

/** Refreshes everything the settings surface shows; runs each time it opens. */
export function loadSettingsSurface(): void {
	settingsActions.load();
	settingsActions.loadDefaultBrowserStatus();
	settingsActions.loadSitePermissions();
	settingsActions.loadWebsiteData();
	settingsActions.loadZoomLevels();
	featureFlagsActions.load();
	settingsActions.loadDeviceSetup();
	settingsActions.loadTerminalOptions();
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

// The sheet is hosted by the settings frame, not the row that opens it, so it overlays the
// whole surface and survives the row scrolling away.
export function isClearDataSheetOpen(): boolean {
	return _clearDataSheetOpen;
}

export function setClearDataSheetOpen(open: boolean): void {
	_clearDataSheetOpen = open;
}

export function getAppIcons(): { id: string; dataURL: string }[] {
	return _appIcons;
}

/** The preview of the app icon chosen in the settings, once the previews are loaded. */
export function getChosenAppIcon(): string | undefined {
	return _appIcons.find((icon) => icon.id === getSetting("appIcon", "pixel"))?.dataURL;
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
