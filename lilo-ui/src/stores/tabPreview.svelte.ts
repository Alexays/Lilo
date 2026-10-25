// At most one requestTabPreview is in flight. A cached reply with an empty image records "no preview", so a
// discarded tab isn't re-requested on every sweep.

import { on } from "../lib/bridge";
import { tabActions } from "../lib/bridge/actions";
import type { BridgeTerminalPrompt } from "../lib/bridge/protocol";

const TAB_PREVIEW_HOVER_DELAY_MS = 450;
const TAB_PREVIEW_CACHE_TTL_MS = 30_000;
// A cached image older than this is shown instantly but refreshed in the background, and the
// visible card refreshes on this cadence so live pages stay live.
const TAB_PREVIEW_REFRESH_MS = 1_000;
// The cadence doubles up to this cap while the card stays up: a tick costs a full render of the
// target tab plus a JPEG encode, and a preview held open for ten seconds is being read, not
// watched. A new hover starts back at the fast cadence.
const TAB_PREVIEW_REFRESH_CAP_MS = 8_000;
// Entries pin full base64 JPEG strings in the JS heap; without a cap, one hover over each of N
// rows retains N images (including closed tabs') for the rest of the session.
const TAB_PREVIEW_CACHE_MAX_ENTRIES = 8;
// Time to cross the gap between a row and a card offering answers.
const TAB_PREVIEW_LEAVE_GRACE_MS = 250;
// A request with no reply by then counts as lost, so one dropped reply can't stall previews.
const TAB_PREVIEW_IN_FLIGHT_TIMEOUT_MS = 3_000;

interface TabPreviewTarget {
	id: string;
	title: string;
	url: string;
	favicon?: string;
}

/** The hovered row's rect: the card opens beside it, away from the tabs' edge. */
interface TabPreviewAnchor {
	top: number;
	right: number;
	bottom: number;
	left: number;
}

interface ShownTabPreview {
	tabId: string;
	title: string;
	url: string;
	favicon: string;
	image: string;
	terminal: BridgeTerminalPrompt | null;
	anchor: TabPreviewAnchor;
}

interface CacheEntry {
	image: string;
	terminal: BridgeTerminalPrompt | null;
	url: string;
	at: number;
}

const cache = new Map<string, CacheEntry>();

// Raw: always replaced whole, so the base64 image and terminal lines are never proxied.
let _preview = $state.raw<ShownTabPreview | null>(null);
// Split out of `_preview` so the 1 Hz image refresh doesn't invalidate every sidebar row: rows
// only ask which tab the card is showing, and that changes once per hover.
let _previewTabId = $state<string | null>(null);
let hovered: {
	target: TabPreviewTarget;
	anchor: TabPreviewAnchor;
	delayElapsed: boolean;
} | null = null;
let hoverTimer: ReturnType<typeof setTimeout> | null = null;
let inFlight: { tabId: string; url: string; at: number } | null = null;

on("tabPreviewReady", (data) => {
	if (!inFlight || inFlight.tabId !== data.tabId) return;
	// Delete-then-set so a re-previewed tab counts as most recently inserted.
	cache.delete(data.tabId);
	const terminal = data.lines?.length
		? { lines: data.lines, question: data.question ?? "", choices: data.choices ?? [] }
		: null;
	cache.set(data.tabId, {
		image: data.image ?? "",
		terminal,
		url: inFlight.url,
		at: Date.now(),
	});
	// Map iterates in insertion order: sweep expired entries, then trim oldest past the cap.
	const now = Date.now();
	for (const [id, entry] of cache) {
		if (now - entry.at > TAB_PREVIEW_CACHE_TTL_MS) cache.delete(id);
	}
	while (cache.size > TAB_PREVIEW_CACHE_MAX_ENTRIES) {
		const oldest = cache.keys().next().value;
		if (oldest === undefined) break;
		cache.delete(oldest);
	}
	inFlight = null;
	// A fresher frame for the visible card swaps in place (stale-while-revalidate).
	if (_preview && _preview.tabId === data.tabId && (data.image || terminal)) {
		_preview = { ..._preview, image: data.image ?? "", terminal };
	}
	// The hovered tab may be this one (show it) or a later hover that queued behind the
	// single-request limit (issue its request now).
	presentOrRequest();
});

function validCacheEntry(target: TabPreviewTarget): CacheEntry | undefined {
	const entry = cache.get(target.id);
	if (!entry) return undefined;
	if (entry.url !== target.url || Date.now() - entry.at > TAB_PREVIEW_CACHE_TTL_MS) {
		cache.delete(target.id);
		return undefined;
	}
	return entry;
}

// `staleAfterMs` is the cadence that just elapsed when called from a refresh tick.
function presentOrRequest(staleAfterMs = refreshIntervalMs): void {
	if (!hovered?.delayElapsed) return;
	const { target, anchor } = hovered;
	const entry = validCacheEntry(target);
	if (entry?.image || entry?.terminal) {
		_preview = { tabId: target.id, title: target.title, url: target.url, favicon: target.favicon ?? "", image: entry.image, terminal: entry.terminal, anchor };
		_previewTabId = target.id;
	}
	// The refresh loop re-enters here every cadence tick for as long as the hover lasts.
	scheduleVisibleRefresh();
	// Serve the cache instantly but keep it fresh: request again once the entry ages past the
	// refresh cadence (stale-while-revalidate; the reply swaps the visible image in place).
	if (inFlight && Date.now() - inFlight.at < TAB_PREVIEW_IN_FLIGHT_TIMEOUT_MS) return;
	// An empty image records "no preview available": negative for the entry's whole TTL, so a held
	// hover doesn't re-request it every cadence tick. Expiry drops the entry and allows a retry.
	if (entry && !entry.image && !entry.terminal) return;
	if (entry && Date.now() - entry.at < staleAfterMs) return;
	inFlight = { tabId: target.id, url: target.url, at: Date.now() };
	tabActions.requestPreview(target.id);
}

let refreshTimer: ReturnType<typeof setTimeout> | null = null;
let refreshIntervalMs = TAB_PREVIEW_REFRESH_MS;

function scheduleVisibleRefresh(): void {
	if (refreshTimer !== null) return;
	refreshTimer = setTimeout(() => {
		refreshTimer = null;
		const elapsed = refreshIntervalMs;
		refreshIntervalMs = Math.min(elapsed * 2, TAB_PREVIEW_REFRESH_CAP_MS);
		if (hovered?.delayElapsed) presentOrRequest(elapsed);
	}, refreshIntervalMs);
}

/** Arm a preview for a hovered sidebar row. Call clearTabPreview on mouseleave. */
export function hoverTabPreview(
	target: TabPreviewTarget,
	anchor: TabPreviewAnchor,
): void {
	if (hovered?.target.id === target.id) return holdTabPreview();
	clearTabPreview();
	refreshIntervalMs = TAB_PREVIEW_REFRESH_MS;
	hovered = { target, anchor, delayElapsed: false };
	hoverTimer = setTimeout(() => {
		hoverTimer = null;
		if (hovered) hovered.delayElapsed = true;
		presentOrRequest();
	}, TAB_PREVIEW_HOVER_DELAY_MS);
}

let leaveTimer: ReturnType<typeof setTimeout> | null = null;

/** The pointer left the row: hide the card, after a grace period when it offers answers. */
export function leaveTabPreview(): void {
	if (!_preview?.terminal?.choices.length) return clearTabPreview();
	if (leaveTimer === null) leaveTimer = setTimeout(clearTabPreview, TAB_PREVIEW_LEAVE_GRACE_MS);
}

/** The pointer reached the card: keep it up. */
export function holdTabPreview(): void {
	if (leaveTimer !== null) {
		clearTimeout(leaveTimer);
		leaveTimer = null;
	}
}

/** Hide the card and cancel any pending hover. An in-flight request just fills the cache. */
export function clearTabPreview(): void {
	holdTabPreview();
	if (hoverTimer !== null) {
		clearTimeout(hoverTimer);
		hoverTimer = null;
	}
	if (refreshTimer !== null) {
		clearTimeout(refreshTimer);
		refreshTimer = null;
	}
	hovered = null;
	_preview = null;
	_previewTabId = null;
}

export function getTabPreview(): ShownTabPreview | null {
	return _preview;
}

/** Tab the preview card is currently showing, if any. Stable across image refreshes. */
export function getTabPreviewTabId(): string | null {
	return _previewTabId;
}
