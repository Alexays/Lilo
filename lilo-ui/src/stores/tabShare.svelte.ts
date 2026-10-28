import { on } from "../lib/bridge";
import { tabActions, tabShareActions } from "../lib/bridge/actions";
import type { BridgeTabShareAudio } from "../lib/bridge/protocol";

interface TabShareRequest {
	requestId: string;
	origin: string;
	shareableTabIds: Set<string>;
	suggestedTabIds: string[];
	allowsSystem: boolean;
	/** Present when the page asked for sound. */
	audio: BridgeTabShareAudio | null;
}

// A snapshot with no reply by then counts as lost, so one dropped reply can't stall the rest.
const THUMBNAIL_TIMEOUT_MS = 3_000;

let _request = $state<TabShareRequest | null>(null);
// Raw: replaced whole, so the base64 images are never proxied. "" records a tab with no snapshot.
let _thumbnails = $state.raw<Record<string, string>>({});
// One snapshot at a time: each is a render of the tab plus a JPEG encode.
let queue: string[] = [];
let inFlight: string | null = null;
let inFlightTimer: ReturnType<typeof setTimeout> | null = null;

function pump(): void {
	if (inFlight || !_request) return;
	const next = queue.shift();
	if (next === undefined) return;
	inFlight = next;
	inFlightTimer = setTimeout(() => settle(next, ""), THUMBNAIL_TIMEOUT_MS);
	tabActions.requestPreview(next);
}

function settle(tabId: string, image: string): void {
	if (inFlight !== tabId) return;
	if (inFlightTimer !== null) clearTimeout(inFlightTimer);
	inFlight = null;
	inFlightTimer = null;
	_thumbnails = { ..._thumbnails, [tabId]: image };
	pump();
}

function clear(): void {
	_request = null;
	_thumbnails = {};
	queue = [];
	if (inFlightTimer !== null) clearTimeout(inFlightTimer);
	inFlight = null;
	inFlightTimer = null;
}

export function initTabShareStore(): void {
	on("tabSharePickerRequested", (data) => {
		// One picker at a time: a request arriving while another is shown is
		// cancelled immediately so its page promise settles.
		if (_request) {
			tabShareActions.resolve({ requestId: data.requestId, choice: "cancel" });
			return;
		}
		_request = {
			requestId: data.requestId,
			origin: data.origin,
			shareableTabIds: new Set(data.shareableTabIds),
			suggestedTabIds: data.suggestedTabIds ?? [],
			allowsSystem: data.allowsSystem !== false,
			audio: data.audio ?? null,
		};
	});

	on("tabSharePickerDismissed", (data) => {
		if (_request?.requestId === data.requestId) clear();
	});
	// The sidebar's hover card asks for the same snapshots: only the one this store asked for counts.
	on("tabPreviewReady", (data) => settle(data.tabId, data.image ?? ""));
}

export function getTabShareRequest(): TabShareRequest | null {
	return _request;
}

/** The tab's snapshot as a data URL; "" when it has none, undefined until asked for and answered. */
export function getTabShareThumbnail(tabId: string): string | undefined {
	return _thumbnails[tabId];
}

/** Queues a snapshot of a card that came into view; each tab is snapshotted once per picker. */
export function requestTabShareThumbnail(tabId: string): void {
	if (!_request || tabId in _thumbnails || tabId === inFlight || queue.includes(tabId)) return;
	queue.push(tabId);
	pump();
}

/** `audio` is the window or screen's "Share audio too" toggle, sent only when the page asked for sound; a tab shares no sound. */
export function resolveTabShare(
	choice: "tab" | "system" | "cancel",
	tabId?: string,
	audio = false,
): void {
	if (!_request) return;
	tabShareActions.resolve({
		requestId: _request.requestId,
		choice,
		...(choice === "tab" && tabId ? { tabId } : {}),
		...(_request.audio && choice === "system" ? { audio } : {}),
	});
	clear();
}
