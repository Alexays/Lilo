import { on } from "../lib/bridge";
import { t } from "../lib/i18n/state.svelte";
import { screenshotActions } from "../lib/bridge/actions";
import {
	closeActivePanel,
	getActivePanel,
	openScreenshotPanel,
} from "./panels.svelte";
import { createHistory, type History } from "../lib/screenshot/history";
import { createAnnotation as createAnnotationFn, resizeAnnotation as resizeAnnotationFn } from "../lib/screenshot/annotationModel";
import type { Annotation, Box, ToolKind, Handle } from "../lib/screenshot/annotationModel";
import type { ScreenshotExport } from "../lib/bridge/protocol";
import type { InkStyle } from "../lib/ink";

interface CapturedImage {
	id: string;
	url: string;
	filename: string;
}

type Toast = { kind: "saved" | "copied" | "notice" | "error"; message: string };
type Flattener = () => Promise<string | null>;

let _open = $state(false);
let _captured = $state<CapturedImage | null>(null);
// From the start of a full-page capture until its image has loaded: seconds on a long page.
let _loading = $state(false);
// The user closed the editor while a capture was still running, so its result is unwanted.
let dropPendingCapture = false;
// The editor asked for a save: a capture card's save must not close it on another capture.
let savePending = false;
let _toast = $state<Toast | null>(null);

// Persisted across captures (not reset): last tool / colour / stroke.
let _tool = $state<ToolKind>("arrow");
let _color = $state("#ff3b30");
let _strokeWidth = $state(6);
let _fill = $state<InkStyle["fill"]>("none");
let _dash = $state<InkStyle["dash"]>("solid");
let _heads = $state<InkStyle["heads"]>("end");
let _annotations = $state.raw<Annotation[]>([]);
let _crop = $state<Box | null>(null);
let _selectedId = $state<string | null>(null);
let _canUndo = $state(false);
let _canRedo = $state(false);
let _editingTextId = $state<string | null>(null);
let _badgeCounter = $state(1);
// A crop is "pending" (drawn, awaiting confirmation) until applied; switching tools discards a pending crop.
let _cropApplied = $state(false);

/** Annotations drawn as a line, which take a dash style. */
export const LINE_TYPES = new Set<Annotation["type"]>(["arrow", "rect", "ellipse", "draw"]);

let history: History<Annotation[]> = createHistory<Annotation[]>([]);
let flattener: Flattener | null = null;
let toastTimer: ReturnType<typeof setTimeout> | undefined;

// Shows a toast and auto-dismisses it after a short delay (replacing any previous one).
function showToast(toast: Toast): void {
	_toast = toast;
	if (toastTimer) clearTimeout(toastTimer);
	// A notice is a sentence to read, not a confirmation to glance at.
	toastTimer = setTimeout(() => { _toast = null; }, toast.kind === "notice" ? 6000 : 2600);
}

function syncFlags(): void {
	_canUndo = history.canUndo();
	_canRedo = history.canRedo();
}

function resetEditing(): void {
	history = createHistory<Annotation[]>([]);
	_annotations = [];
	_crop = null;
	_cropApplied = false;
	_selectedId = null;
	_editingTextId = null;
	_badgeCounter = 1;
	syncFlags();
}

function doCommit(next: Annotation[]): void {
	_annotations = next;
	history.push(next);
	syncFlags();
}

/** Applies `patch` to the selected annotation and records one undo step. No-op if nothing selected. */
function updateSelected(patch: (a: Annotation) => Annotation): boolean {
	const id = _selectedId;
	if (!id) return false;
	doCommit(_annotations.map((a) => (a.id === id ? patch(a) : a)));
	return true;
}

// The flattener stays registered: ScreenshotEditor.svelte registers it once per app session, so clearing it here
// would break Save / Copy on every later capture. It returns null while the editor DOM is unmounted.
function doClose(): void {
	if (_open && !_captured && _loading) dropPendingCapture = true;
	_open = false;
	_loading = false;
	_captured = null;
	savePending = false;
	resetEditing();
	if (getActivePanel() === "screenshot") closeActivePanel();
}

// Without annotations native exports its own PNG, so a capture too big for a canvas still saves.
// Reports a failed flatten itself, so callers only act on a real export.
async function exportNow(): Promise<ScreenshotExport | null> {
	if (!_captured) return null;
	if (_annotations.length === 0) return { id: _captured.id, crop: _crop };
	const png = flattener ? await flattener().catch(() => null) : null;
	if (!png) {
		showToast({ kind: "error", message: t("screenshot.exportFailed") });
		return null;
	}
	return { id: _captured.id, dataURL: png };
}

export const screenshotEditor = {
	get open(): boolean { return _open; },
	get captured(): CapturedImage | null { return _captured; },
	get loading(): boolean { return _loading; },
	get toast(): Toast | null { return _toast; },
	get tool(): ToolKind { return _tool; },
	get color(): string { return _color; },
	get strokeWidth(): number { return _strokeWidth; },
	/** The look the next annotation takes, as the style panel shows it. */
	get style(): InkStyle { return { color: _color, width: _strokeWidth, fill: _fill, dash: _dash, heads: _heads }; },
	get annotations(): Annotation[] { return _annotations; },
	get crop(): Box | null { return _crop; },
	get selectedId(): string | null { return _selectedId; },
	get canUndo(): boolean { return _canUndo; },
	get canRedo(): boolean { return _canRedo; },
	get editingTextId(): string | null { return _editingTextId; },
	get cropApplied(): boolean { return _cropApplied; },

	setTool(tool: ToolKind): void {
		// Changing tools discards a crop the user never confirmed.
		if (_crop && !_cropApplied) { _crop = null; }
		_tool = tool;
	},
	/** Sets the next annotations' look and, for what applies to it, the selected one's. */
	setStyle(patch: Partial<InkStyle>): void {
		if (patch.fill) _fill = patch.fill;
		if (patch.dash) _dash = patch.dash;
		if (patch.heads) _heads = patch.heads;
		if (patch.color) _color = patch.color;
		if (patch.width) _strokeWidth = patch.width;
		updateSelected((a) => ({
			...a,
			...(patch.color ? { color: patch.color } : {}),
			...(patch.width ? { strokeWidth: patch.width } : {}),
			...(patch.fill && (a.type === "rect" || a.type === "ellipse") ? { fill: patch.fill } : {}),
			...(patch.dash && LINE_TYPES.has(a.type) ? { dash: patch.dash } : {}),
			...(patch.heads && a.type === "arrow" ? { heads: patch.heads } : {}),
		}));
	},
	// Reorders the whole z-stack to match `idsBottomToTop` (array order = paint order).
	reorderAnnotations(idsBottomToTop: string[]): void {
		const byId = new Map(_annotations.map((a) => [a.id, a]));
		const next = idsBottomToTop.map((id) => byId.get(id)).filter((a): a is Annotation => !!a);
		if (next.length === _annotations.length) doCommit(next);
	},
	// Deletes a specific annotation (used by the layers list).
	deleteAnnotation(id: string): void {
		doCommit(_annotations.filter((a) => a.id !== id));
		if (_selectedId === id) _selectedId = null;
	},
	// Transient handle-drag resize of the selected annotation (history pushed on pointer-up).
	resizeSelected(handle: Handle, dx: number, dy: number): void {
		const id = _selectedId;
		if (!id) return;
		_annotations = _annotations.map((a) => (a.id === id ? resizeAnnotationFn(a, handle, dx, dy) : a));
	},
	setCrop(crop: Box | null): void {
		_crop = crop;
		if (crop === null) _cropApplied = false;
	},
	// Confirm the pending crop: keep it as export bounds and return to the select tool.
	applyCrop(): void {
		if (!_crop) return;
		_cropApplied = true;
		_tool = "select";
	},
	select(id: string | null): void { _selectedId = id; },

	// Transient update during a drag (no history entry).
	setAnnotations(next: Annotation[]): void { _annotations = next; },
	// Commit a new annotation set as one undo step.
	commit(next: Annotation[]): void { doCommit(next); },
	// Snapshot the current annotations as one undo step (used after a move drag).
	pushHistory(): void { history.push(_annotations); syncFlags(); },

	undo(): void { _annotations = [...history.undo()]; _selectedId = null; syncFlags(); },
	redo(): void { _annotations = [...history.redo()]; _selectedId = null; syncFlags(); },
	deleteSelected(): void {
		if (!_selectedId) return;
		doCommit(_annotations.filter((a) => a.id !== _selectedId));
		_selectedId = null;
	},

	// Places an auto-numbered badge centred on (x, y) and records one undo step.
	placeBadge(x: number, y: number): void {
		const r = Math.max(12, _strokeWidth * 5);
		const a = createAnnotationFn("badge", { x: x - r, y: y - r, w: r * 2, h: r * 2 }, _color, _strokeWidth, String(_badgeCounter));
		_badgeCounter += 1;
		doCommit([..._annotations, a]);
	},

	// --- Text editing (inline) ---
	// Adds a fresh text annotation and opens it for editing (no history entry until committed).
	addTextAnnotation(a: Annotation): void {
		_annotations = [..._annotations, a];
		_editingTextId = a.id;
	},
	// Re-open an existing text annotation for editing.
	startEditingText(id: string): void { _editingTextId = id; },
	// Live-update the text being edited (transient, no history entry).
	setEditingText(text: string): void {
		const id = _editingTextId;
		if (!id) return;
		_annotations = _annotations.map((a) => (a.id === id ? { ...a, text } : a));
	},
	// Finish editing: drop empty text (no history), otherwise record one undo step.
	commitTextEdit(): void {
		const id = _editingTextId;
		_editingTextId = null;
		if (!id) return;
		const a = _annotations.find((x) => x.id === id);
		if (!a || !(a.text ?? "").trim()) {
			_annotations = _annotations.filter((x) => x.id !== id);
		} else {
			// Give the text a real bounding box (it was created 0×0) so it can be hit-tested,
			// selected and re-edited (double-click). Estimated from the glyph metrics.
			const fontSize = Math.max(16, a.strokeWidth * 6);
			const text = a.text ?? "";
			const w = Math.max(fontSize, text.length * fontSize * 0.58);
			const h = fontSize * 1.3;
			_annotations = _annotations.map((x) => (x.id === id ? { ...x, box: { ...x.box, w, h } } : x));
			history.push(_annotations);
			syncFlags();
		}
	},

	registerFlattener(fn: Flattener): void { flattener = fn; },

	async save(): Promise<void> {
		const capture = await exportNow();
		if (!capture || !_captured) return;
		savePending = true;
		screenshotActions.saveDefault(capture, _captured.filename);
	},
	async saveAs(): Promise<void> {
		const capture = await exportNow();
		if (!capture || !_captured) return;
		savePending = true;
		screenshotActions.saveAs(capture, _captured.filename);
	},
	async copy(): Promise<void> {
		const capture = await exportNow();
		if (!capture) return;
		screenshotActions.copy(capture);
		doClose();
		showToast({ kind: "copied", message: t("screenshot.copied") });
	},
	cancel(): void {
		if (_captured) screenshotActions.cancel(_captured.id);
		doClose();
	},
	close(): void { doClose(); },
	// The capture's image is decoded (or failed to load): the editor can show it.
	imageReady(): void { _loading = false; },
	clearToast(): void {
		_toast = null;
		if (toastTimer) clearTimeout(toastTimer);
	},
};

/** Wire native screenshot events to the store. Call once at app init. */
export function initScreenshotEditor(): void {
	on("screenshotCapturing", () => {
		dropPendingCapture = false;
		_captured = null;
		resetEditing();
		_loading = true;
		_open = true;
		openScreenshotPanel();
	});
	on("screenshotCaptured", (data) => {
		if (dropPendingCapture) {
			dropPendingCapture = false;
			screenshotActions.cancel(data.id);
			return;
		}
		_captured = { id: data.id, url: data.url, filename: data.filename };
		resetEditing();
		_loading = true;
		_open = true;
		openScreenshotPanel();
		if (data.truncated) showToast({ kind: "notice", message: t("screenshot.truncated") });
	});
	on("screenshotSaved", (data) => {
		if (savePending) doClose();
		showToast({ kind: "saved", message: data.path });
	});
	on("screenshotError", (data) => {
		if (_loading && !_captured) doClose();
		dropPendingCapture = false;
		savePending = false;
		showToast({ kind: "error", message: data.message });
	});
}
