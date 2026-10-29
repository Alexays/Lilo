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
		announce(undoToastSubject(_toast));
		// Replaced under the pointer: stay paused, and resume with a full window.
		if (paused) {
			remainingMs = UNDO_TOAST_DURATION_MS;
			return;
		}
		if (timer !== null) clearTimeout(timer);
		startTimer(UNDO_TOAST_DURATION_MS);
	});
}

// Cmd+Z takes the toast's offer only from the chrome outside a text field: a field keeps its own undo, and a focused page
// never sends its keys here. Listening only while the toast shows lets an overlay's own Cmd+Z, attached earlier, go first.
function undoOnCommandZ(e: KeyboardEvent): void {
	if (e.defaultPrevented || !e.metaKey || e.shiftKey || e.altKey || e.ctrlKey || e.key.toLowerCase() !== "z") return;
	if (e.target instanceof Element && e.target.closest("input, textarea, select, [contenteditable]:not([contenteditable=false])")) return;
	e.preventDefault();
	undoTabClose();
}

function clearToast(): void {
	_toast = null;
	window.removeEventListener("keydown", undoOnCommandZ);
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
	window.addEventListener("keydown", undoOnCommandZ);
	timer = setTimeout(() => {
		timer = null;
		clearToast();
	}, ms);
}

/** What the toast undoes: the tab or tabs a close took away, or put in the archive. */
export function undoToastSubject(toast: UndoToast): string {
	if (toast.label) return toast.label;
	if (toast.archivedIds) return toast.count > 1 ? t("undoToast.archivedCount", { count: toast.count }) : t("undoToast.archived", { title: toast.title });
	return toast.count > 1 ? t("undoToast.closedCount", { count: toast.count }) : t("undoToast.closed", { title: toast.title });
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
	clearToast();
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
