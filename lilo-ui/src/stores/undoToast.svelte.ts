// A new close replaces the current toast and restarts its auto-dismiss; a Clear names the tabs it archived, which
// come back from the archive.

import { on } from "../lib/bridge";
import { tabActions } from "../lib/bridge/actions";
import { announce } from "../lib/announce";
import { t } from "../lib/i18n/state.svelte";

export const UNDO_TOAST_DURATION_MS = 5000;

// `label` and `undo` make it the undo of something other than a tab close.
type UndoToast = { title: string; count: number; seq: number; archivedIds?: string[]; label?: string; undo?: () => void };

let _toast = $state<UndoToast | null>(null);
// Bumped on every close so the view can restart the countdown ring on a replacement.
let seq = 0;
let timer: ReturnType<typeof setTimeout> | null = null;
let remainingMs = 0;
let resumedAt = 0;

export function initUndoToastStore(): void {
	on("tabClosedUndoable", (data) => {
		const paused = _toast !== null && timer === null;
		_toast = { title: data.title, count: data.count ?? 1, seq: ++seq, ...(data.archivedIds && { archivedIds: data.archivedIds }) };
		announce(_toast.count > 1 ? t("undoToast.closedCount", { count: _toast.count }) : t("undoToast.closed", { title: _toast.title }));
		// Replaced under the pointer: stay paused, and resume with a full window.
		if (paused) {
			remainingMs = UNDO_TOAST_DURATION_MS;
			return;
		}
		if (timer !== null) clearTimeout(timer);
		startTimer(UNDO_TOAST_DURATION_MS);
	});
}

export function showUndoToast(label: string, undo: () => void): void {
	if (timer !== null) clearTimeout(timer);
	_toast = { title: label, count: 1, seq: ++seq, label, undo };
	announce(label);
	startTimer(UNDO_TOAST_DURATION_MS);
}

function startTimer(ms: number): void {
	remainingMs = ms;
	resumedAt = Date.now();
	timer = setTimeout(() => {
		timer = null;
		_toast = null;
	}, ms);
}

export function getUndoToast(): UndoToast | null {
	return _toast;
}

export function pauseUndoToast(): void {
	if (timer === null) return;
	clearTimeout(timer);
	timer = null;
	remainingMs = Math.max(0, remainingMs - (Date.now() - resumedAt));
}

export function resumeUndoToast(): void {
	if (_toast === null || timer !== null) return;
	startTimer(remainingMs);
}

function dismissUndoToast(): void {
	if (timer !== null) {
		clearTimeout(timer);
		timer = null;
	}
	_toast = null;
}

export function undoTabClose(): void {
	if (_toast?.undo) {
		_toast.undo();
	} else if (_toast?.archivedIds) {
		tabActions.restoreArchived(_toast.archivedIds);
	} else {
		// One restore per entry the batch pushed; the host pops them newest-first.
		for (let i = _toast?.count ?? 1; i > 0; i--) tabActions.restoreClosed();
	}
	dismissUndoToast();
}
