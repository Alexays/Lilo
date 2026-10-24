// Everything that drops out of the address bar: permission requests, the default-browser invite,
// and the Site drawer the user opens. One drawer shows at a time, picked by priority.

import { on } from "../lib/bridge";
import { agentActions, chromeActions, extensionActions, settingsActions } from "../lib/bridge/actions";
import type { BridgeAgentAction } from "../lib/bridge/protocol";
import { getOnboarding } from "./onboarding.svelte";
import { getActiveSpaceId } from "./spaces.svelte";
import { getActiveTabId } from "./tabs.svelte";

interface SitePermissionRequest {
	kind: "sitePermission";
	requestId: string;
	tabId: string;
	type: string;
	origin: string;
}

interface ExtensionPermissionRequest {
	kind: "extensionPermission";
	requestId: string;
	spaceId: string;
	extensionName: string;
	permissions: string[];
	origins: string[];
	type: "permissions" | "urls" | "matchPatterns";
}

interface AgentControlRequest {
	kind: "agentControl";
	requestId: string;
	clientName: string;
	/** The program asking to connect, empty for a client already allowed. */
	executable: string;
	/** Set when the agent asks for another profile rather than to connect. */
	profileName: string;
	/** Set when the agent is about to send, pay, delete or publish. */
	action?: BridgeAgentAction | null;
}

export type PermissionRequest = SitePermissionRequest | ExtensionPermissionRequest | AgentControlRequest;

export type UrlBarDrawer =
	| PermissionRequest
	| { kind: "defaultBrowser" }
	| { kind: "site" };

const DEFAULT_BROWSER_DRAWER = { kind: "defaultBrowser" } as const;
const SITE_DRAWER = { kind: "site" } as const;

let _queue = $state.raw<PermissionRequest[]>([]);
let _defaultBrowserInvite = $state(false);
let _siteOpen = $state(false);
let _trackersBlocked = $state(0);
let _blockerAllowlist = $state.raw<string[]>([]);
// Zoom the host reported for the active tab; null until it changes during this session.
let _pageZoom = $state<{ tabId: string; level: number } | null>(null);

export function initUrlBarDrawerStore(): void {
	on("permissionRequest", (data) => {
		_queue = [
			..._queue,
			{
				kind: "sitePermission",
				requestId: data.requestId,
				tabId: data.tabId,
				type: data.type ?? "media",
				origin: data.origin ?? "",
			},
		];
	});
	on("permissionRequestClosed", (data) => {
		_queue = _queue.filter((request) => request.requestId !== data.requestId);
	});
	on("extensionPermissionRequested", (data) => {
		_queue = [
			..._queue,
			{
				kind: "extensionPermission",
				requestId: data.requestId,
				// An extension prompt belongs to the space it was granted in.
				spaceId: getActiveSpaceId(),
				extensionName: data.extensionName,
				permissions: data.permissions ?? [],
				origins: data.origins ?? [],
				type: data.type,
			},
		];
	});
	on("agentControlRequested", (data) => {
		_queue = [
			..._queue,
			{
				kind: "agentControl",
				requestId: data.requestId,
				clientName: data.clientName,
				executable: data.executable ?? "",
				profileName: data.profileName ?? "",
				action: data.action,
			},
		];
	});
	on("defaultBrowserStatusLoaded", (data) => {
		_defaultBrowserInvite = data.shouldInvite;
	});
	on("trackersBlockedChanged", (data) => {
		_trackersBlocked = data.count;
	});
	on("settingsLoaded", (data) => {
		try {
			const parsed: unknown = JSON.parse(data.settings?.["contentBlockerAllowlist"] ?? "[]");
			_blockerAllowlist = Array.isArray(parsed) ? parsed : [];
		} catch {
			_blockerAllowlist = [];
		}
	});
	on("blockerAllowlistChanged", (data) => {
		_blockerAllowlist = data.allowlist ?? [];
	});
	on("zoomChanged", (data) => {
		_pageZoom = { tabId: getActiveTabId(), level: typeof data.level === "number" ? data.level : 1 };
	});
}

/**
 * Priority: a site prompt from the active tab, an extension prompt from the active space, an agent asking to
 * control Lilo whatever is shown, the default-browser invite, then the Site drawer the user opened.
 */
export function getActiveUrlBarDrawer(): UrlBarDrawer | null {
	const tabId = getActiveTabId();
	const spaceId = getActiveSpaceId();
	return (
		_queue.find((request) => request.kind === "sitePermission" && request.tabId === tabId) ??
		_queue.find((request) => request.kind === "extensionPermission" && request.spaceId === spaceId) ??
		_queue.find((request) => request.kind === "agentControl") ??
		// The onboarding has its own default-browser step.
		(_defaultBrowserInvite && !getOnboarding().visible ? DEFAULT_BROWSER_DRAWER : null) ??
		(_siteOpen ? SITE_DRAWER : null)
	);
}

/** `alwaysAllowSite` answers an agent's action, allowing it on that site from now on. */
export function respondToPermissionRequest(request: PermissionRequest, granted: boolean, alwaysAllowSite?: string): void {
	if (request.kind === "sitePermission") chromeActions.permissionResponse(request.requestId, granted);
	else if (request.kind === "agentControl") agentActions.respond(request.requestId, granted, alwaysAllowSite);
	else extensionActions.permissionResponse(request.requestId, granted);
	_queue = _queue.filter((candidate) => candidate.requestId !== request.requestId);
	// A request that took over the Site drawer does not hand it back once answered.
	_siteOpen = false;
}

/** Escape on a site's request: denied for now, so the site may ask again. */
export function dismissSitePermissionRequest(requestId: string): void {
	chromeActions.dismissPermissionRequest(requestId);
	_queue = _queue.filter((candidate) => candidate.requestId !== requestId);
	_siteOpen = false;
}

export function isSiteDrawerOpen(): boolean {
	return _siteOpen;
}

export function setSiteDrawerOpen(open: boolean): void {
	_siteOpen = open;
}

export function dismissDefaultBrowserInvite(): void {
	settingsActions.dismissDefaultBrowserInvite();
	_defaultBrowserInvite = false;
}

/** Hides the invite without recording a dismissal (Lilo just became the default). */
export function hideDefaultBrowserInvite(): void {
	_defaultBrowserInvite = false;
}

export function getTrackersBlocked(): number {
	return _trackersBlocked;
}

export function isBlockerAllowlisted(host: string): boolean {
	return _blockerAllowlist.includes(host);
}

/** The active tab's zoom when it changed this session, else `fallback`. */
export function getPageZoom(fallback: number): number {
	return _pageZoom && _pageZoom.tabId === getActiveTabId() ? _pageZoom.level : fallback;
}
