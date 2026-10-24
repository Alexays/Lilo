// Extension store: tracks installed extensions from Swift backend.

import {
	on,
	type BridgeExtensionSnapshot,
	type BridgeExtensionUpdateCheck,
	type BridgeInitialStatePayload,
} from "../lib/bridge";
import { extensionActions } from "../lib/bridge/actions";
import {
	coerceRuntimeStatus,
	type ExtensionRuntimeStatus,
} from "../components/extensions/extensionPanelModel";
import { getActiveProfileId, getProfileById } from "./profiles.svelte";
import { getActiveSpace } from "./spaces.svelte";

export interface ExtensionState extends BridgeExtensionSnapshot {
	runtimeStatus: ExtensionRuntimeStatus;
	/** Set on the rows of a profile the window does not show: every action names it. */
	profileId?: string;
}

// Raw: every `extensionsChanged` (badge updates land during page loads) rebuilds the list,
// so deep proxies over each extension and its permission arrays would be rebuilt for nothing.
let _extensions = $state.raw<ExtensionState[]>([]);

// Each command's intent is tracked here until `extensionsChanged` or its `extensionActionCompleted` ack confirms
// it, keeping the toggles from showing a state the backend hasn't reached.
type PendingAction = "enable" | "disable" | "uninstall";

interface PendingEntry {
	action: PendingAction;
	timeout: ReturnType<typeof setTimeout>;
	profileId?: string;
}

// If no `extensionsChanged` snapshot confirms the action within this window we treat it as
// failed, clear the pending state (so the UI never gets stuck), and surface an inline error.
const PENDING_TIMEOUT_MS = 8000;

let _pending = $state.raw<Record<string, PendingEntry>>({});
let _errors = $state.raw<Record<string, boolean>>({});
// Updates download a package, far longer than the pending timeout: they settle only on the native ack.
let _updating = $state.raw<Record<string, boolean>>({});
// A store install waits on a download and the native review dialog: it too settles on the native ack.
let _installing = $state.raw<Record<string, boolean>>({});
let _updateCheck = $state.raw<BridgeExtensionUpdateCheck>({});
let _downloadUiEnabled = $state(true);
// The profile Settings > Extensions shows instead of the window's, and its rows once they arrive.
let _shownProfileId = $state("");
let _profileExtensions = $state.raw<{ profileId: string; live: boolean; extensions: ExtensionState[] } | null>(null);

// Icons are rendered as <img src>; only data:image/ URLs from the native side
// are trusted. Anything else (javascript:, http(s):, arbitrary schemes) is dropped.
function sanitizeIconDataURL(value: unknown): string {
	return typeof value === "string" && /^data:image\//i.test(value) ? value : "";
}

// Badge colors are injected into inline style; only allow simple hex and
// rgb()/rgba() literals so a manifest can't smuggle CSS (e.g. url(), expression()).
function sanitizeBadgeColor(value: unknown): string {
	if (typeof value !== "string") return "";
	const v = value.trim();
	const isHex = /^#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(v);
	const isRgb = /^rgba?\([0-9.,%\s]+\)$/i.test(v);
	return isHex || isRgb ? v : "";
}

function coerceString(value: unknown): string {
	return typeof value === "string" ? value : "";
}

function parseExtension(
	data: BridgeExtensionSnapshot,
	previous?: ExtensionState,
): ExtensionState {
	return {
		id: coerceString(data?.id),
		name: coerceString(data?.name),
		version: coerceString(data?.version),
		description: coerceString(data?.description),
		isEnabled: data?.isEnabled ?? false,
		iconDataURL:
			data?.iconDataURL === undefined && data?.isEnabled
				? (previous?.iconDataURL ?? "")
				: sanitizeIconDataURL(data?.iconDataURL),
		iconVersion: data?.iconVersion ?? 0,
		hasPopup: data?.hasPopup ?? false,
		hasBackground: data?.hasBackground ?? false,
		hasContentScripts: data?.hasContentScripts ?? false,
		runtimeStatus: coerceRuntimeStatus(data?.runtimeStatus),
		badgeText: coerceString(data?.badgeText),
		badgeColor: sanitizeBadgeColor(data?.badgeColor),
		badgeTextColor: sanitizeBadgeColor(data?.badgeTextColor),
		actionEnabled: data?.actionEnabled ?? true,
		actionLabel: coerceString(data?.actionLabel),
		permissions: data?.permissions ?? [],
		hostPermissions: data?.hostPermissions ?? [],
		siteAccess: data?.siteAccess ?? [],
		omniboxKeyword: data?.omniboxKeyword || undefined,
		error: coerceString(data?.error),
		availableUpdate: coerceString(data?.availableUpdate),
		declinedUpdate: coerceString(data?.declinedUpdate),
		webStoreURL: coerceString(data?.webStoreURL),
		allowsPrivateAccess: data?.allowsPrivateAccess ?? false,
		allowsUserScripts: data?.allowsUserScripts ?? false,
		hostAccessRequest: data?.hostAccessRequest ?? false,
		commands: data?.commands ?? [],
	};
}

// True once the snapshot reflects the action's intended outcome, at which point the
// pending state can be cleared.
function isActionSatisfied(
	action: PendingAction,
	snapshot: ExtensionState | undefined,
): boolean {
	switch (action) {
		case "enable":
			return snapshot?.isEnabled === true;
		case "disable":
			return snapshot?.isEnabled === false;
		case "uninstall":
			return snapshot === undefined;
	}
}

function clearPending(id: string): void {
	const entry = _pending[id];
	if (!entry) return;
	clearTimeout(entry.timeout);
	const { [id]: _removed, ...rest } = _pending;
	_pending = rest;
}

// Reconcile every in-flight action on the snapshot's profile against it. Confirmed actions
// clear their pending state; unconfirmed ones keep spinning until they confirm or time out.
function reconcilePending(extensions: ExtensionState[], profileId?: string): void {
	for (const id of Object.keys(_pending)) {
		const entry = _pending[id];
		if (entry.profileId !== profileId) continue;
		const snapshot = extensions.find((e) => e.id === id);
		if (isActionSatisfied(entry.action, snapshot)) clearPending(id);
	}
}

// Begin an in-flight action: record intent, clear any stale error, run the command, and arm
// the failure timeout. Does nothing if an action is already pending for this id, which guards
// against double-submission and toggle races.
function beginAction(id: string, action: PendingAction, profileId: string | undefined, run: () => void): void {
	if (_pending[id]) return;
	clearExtensionError(id);
	const timeout = setTimeout(() => failAction(id), PENDING_TIMEOUT_MS);
	_pending = { ..._pending, [id]: { action, timeout, profileId } };
	run();
}

function failAction(id: string): void {
	clearPending(id);
	_errors = { ..._errors, [id]: true };
}

// Native ack for an in-flight action. Success clears pending promptly (the authoritative
// `extensionsChanged` snapshot, usually already applied, drives the final state); failure
// resolves it crisply instead of waiting out the timeout.
function settleAction(id: string, success: boolean): void {
	if (!_pending[id]) return;
	if (success) {
		clearPending(id);
	} else {
		failAction(id);
	}
}

export function applyExtensionInitialState(
	data: BridgeInitialStatePayload,
): void {
	const extensions = data.extensions;
	_extensions = Array.isArray(extensions)
		? extensions.map((e) => parseExtension(e))
		: [];
	reconcilePending(_extensions);
}

export function initExtensionStore(): void {
	on("extensionsChanged", (data) => {
		const previous = new Map(_extensions.map((e) => [e.id, e]));
		const changed = new Map(
			(Array.isArray(data.extensions) ? data.extensions : []).map((e) => [e.id, e]),
		);
		const next: ExtensionState[] = [];
		for (const id of Array.isArray(data.ids) ? data.ids : []) {
			const row = changed.get(id);
			const kept = previous.get(id);
			if (row) next.push(parseExtension(row, kept));
			else if (kept) next.push(kept);
		}
		_extensions = next;
		if (data.updateCheck) _updateCheck = data.updateCheck;
		_downloadUiEnabled = data.downloadUiEnabled !== false;
		reconcilePending(_extensions);
	});
	on("profileExtensionsLoaded", (data) => {
		if (data.profileId !== _shownProfileId) return;
		const extensions = (Array.isArray(data.extensions) ? data.extensions : []).map((e) => ({
			...parseExtension(e),
			profileId: data.profileId,
		}));
		_profileExtensions = { profileId: data.profileId, live: data.live === true, extensions };
		reconcilePending(extensions, data.profileId);
	});
	on("extensionActionCompleted", (data) => {
		if (typeof data?.id !== "string") return;
		if (data.action === "install") {
			const { [data.id]: _removed, ...rest } = _installing;
			_installing = rest;
			return;
		}
		if (data.action !== "update") {
			settleAction(data.id, data.success === true);
			return;
		}
		const { [data.id]: _removed, ...rest } = _updating;
		_updating = rest;
		if (data.success !== true) _errors = { ..._errors, [data.id]: true };
	});
}

/** False while an extension hid the download UI through chrome.downloads.setUiOptions. */
export function isDownloadUiEnabled(): boolean {
	return _downloadUiEnabled;
}

export function getExtensions(): ExtensionState[] {
	return _extensions;
}

/** The profile Settings > Extensions shows when it is not the window's own; empty otherwise. */
export function getShownExtensionsProfileId(): string {
	return _shownProfileId !== getActiveProfileId() && getProfileById(_shownProfileId) ? _shownProfileId : "";
}

/** Shows `profileId`'s extensions in Settings > Extensions; the window's profile, or "", shows its own. */
export function showProfileExtensions(profileId: string): void {
	const shown = profileId === getActiveProfileId() ? "" : profileId;
	_shownProfileId = shown;
	_profileExtensions = null;
	if (shown) extensionActions.loadProfile(shown, false);
}

/** The rows Settings > Extensions lists: null while another profile's are on their way. */
export function getShownExtensions(): ExtensionState[] | null {
	const profileId = getShownExtensionsProfileId();
	if (!profileId) return _extensions;
	return _profileExtensions?.profileId === profileId ? _profileExtensions.extensions : null;
}

/** False while the shown profile's rows come from storage only: its detail page waits for the full ones. */
export function areShownExtensionsLive(): boolean {
	return !getShownExtensionsProfileId() || _profileExtensions?.live === true;
}

/** Asks for the shown profile's full rows, which restores its registry as showing it in a window would. */
export function loadLiveShownExtensions(): void {
	const profileId = getShownExtensionsProfileId();
	if (profileId) extensionActions.loadProfile(profileId, true);
}

/** The extensions that run where the window is: a private space runs only those allowed there. */
export function getEnabledExtensions(): ExtensionState[] {
	const inPrivateSpace = getActiveSpace()?.isPrivate === true;
	return _extensions.filter((e) => e.isEnabled && (!inPrivateSpace || e.allowsPrivateAccess));
}

/** If `query` is "<keyword> <text>" for an enabled extension's omnibox keyword, resolve the owner. */
export function matchOmniboxKeyword(
	query: string,
): { extensionId: string; keyword: string; text: string } | null {
	const trimmed = query.replace(/^\s+/, "");
	const spaceIndex = trimmed.indexOf(" ");
	if (spaceIndex <= 0) return null;
	const keyword = trimmed.slice(0, spaceIndex);
	const text = trimmed.slice(spaceIndex + 1);
	const lowered = keyword.toLowerCase();
	const owner = getEnabledExtensions().find(
		(e) => e.omniboxKeyword && e.omniboxKeyword.toLowerCase() === lowered,
	);
	return owner ? { extensionId: owner.id, keyword, text } : null;
}

/** Whether an enable/disable/uninstall command is currently in flight for this id. */
export function isExtensionPending(id: string): boolean {
	return _pending[id] !== undefined;
}

export function isExtensionUpdating(id: string): boolean {
	return _updating[id] === true;
}

export function isExtensionInstalling(id: string): boolean {
	return _installing[id] === true;
}

/** Installs a Chrome Web Store extension by id into the current profile. */
export function installStoreExtension(id: string): void {
	if (_installing[id]) return;
	_installing = { ..._installing, [id]: true };
	extensionActions.install(`https://chromewebstore.google.com/detail/${id}`);
}

export function getExtensionUpdateCheck(): BridgeExtensionUpdateCheck {
	return _updateCheck;
}

/** Applies an available update, or asks again for the permissions a declined one adds. */
export function updateExtension(id: string, profileId?: string): void {
	if (_updating[id]) return;
	clearExtensionError(id);
	_updating = { ..._updating, [id]: true };
	extensionActions.update(id, profileId);
}

export function checkExtensionUpdates(): void {
	_updateCheck = { ..._updateCheck, checking: true };
	extensionActions.checkUpdates();
}

/** Whether the last action for this id failed (timed out without confirmation). */
export function hasExtensionError(id: string): boolean {
	return _errors[id] === true;
}

export function clearExtensionError(id: string): void {
	if (!_errors[id]) return;
	const { [id]: _removed, ...rest } = _errors;
	_errors = rest;
}

// `profileId` names a profile the window does not show (ExtensionState.profileId).
export function enableExtension(id: string, profileId?: string): void {
	beginAction(id, "enable", profileId, () => extensionActions.enable(id, profileId));
}

export function disableExtension(id: string, profileId?: string): void {
	beginAction(id, "disable", profileId, () => extensionActions.disable(id, profileId));
}

export function uninstallExtension(id: string, profileId?: string): void {
	beginAction(id, "uninstall", profileId, () => extensionActions.uninstall(id, profileId));
}

