// The card confirming a copied capture; it opens or saves the capture until it goes. A new capture
// replaces the card; the 6 s window pauses while the pointer or focus is on it.

import { on } from "../lib/bridge";
import { screenshotActions } from "../lib/bridge/actions";

export const CAPTURE_CARD_DURATION_MS = 6000;

type CaptureCard = {
	captureId: string;
	thumbURL: string;
	filename: string;
	seq: number;
};

let card = $state<CaptureCard | null>(null);
let seq = 0;
let timer: ReturnType<typeof setTimeout> | null = null;
let remainingMs = 0;
let resumedAt = 0;

export function initCaptureCardStore(): void {
	on("captureCopied", (data) => {
		releaseCopy();
		const paused = card !== null && timer === null;
		card = { captureId: data.captureId, thumbURL: data.thumbURL, filename: data.filename, seq: ++seq };
		// Replaced under the pointer: stay paused, and resume with a full window.
		if (paused) {
			remainingMs = CAPTURE_CARD_DURATION_MS;
			return;
		}
		if (timer !== null) clearTimeout(timer);
		startTimer(CAPTURE_CARD_DURATION_MS);
	});
}

/** A copied capture whose card goes can no longer be opened: the host drops it. */
function releaseCopy(): void {
	if (card) screenshotActions.releaseCopied(card.captureId);
}

function hide(): void {
	if (timer !== null) clearTimeout(timer);
	timer = null;
	card = null;
}

function startTimer(ms: number): void {
	remainingMs = ms;
	resumedAt = Date.now();
	timer = setTimeout(() => {
		releaseCopy();
		hide();
	}, ms);
}

export function getCaptureCard(): CaptureCard | null {
	return card;
}

export function pauseCaptureCard(): void {
	if (timer === null) return;
	clearTimeout(timer);
	timer = null;
	remainingMs = Math.max(0, remainingMs - (Date.now() - resumedAt));
}

export function resumeCaptureCard(): void {
	if (card === null || timer !== null) return;
	startTimer(remainingMs);
}

/** The editor takes the capture over, so it is not released. */
export function editCapture(): void {
	if (!card) return;
	screenshotActions.editCopied(card.captureId);
	hide();
}

/** The host reads the capture as it handles the save, before the release that follows it. */
export function saveCapture(): void {
	if (!card) return;
	screenshotActions.saveDefault({ id: card.captureId }, card.filename);
	releaseCopy();
	hide();
}

export function dismissCapture(): void {
	releaseCopy();
	hide();
}
