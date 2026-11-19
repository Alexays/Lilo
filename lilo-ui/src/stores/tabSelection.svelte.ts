// The sidebar's multi-tab selection: ⌘-click toggles a tab, ⇧-click selects the range back to the
// anchor (the last tab clicked). Ephemeral and per Space: a plain click activates and collapses it.
import { getActiveSpaceId } from "./spaces.svelte";

const EMPTY: ReadonlySet<string> = new Set();

let _spaceId: string | null = null;
let _ids = $state.raw<ReadonlySet<string>>(EMPTY);
let _anchor: string | null = null;

const inActiveSpace = (): boolean => _spaceId !== null && _spaceId === getActiveSpaceId();

export const isTabSelected = (id: string): boolean => inActiveSpace() && _ids.has(id);
export const getSelectedTabIds = (): ReadonlySet<string> => (inActiveSpace() ? _ids : EMPTY);

function commit(ids: ReadonlySet<string>): void {
	_spaceId = getActiveSpaceId();
	_ids = ids;
}

/** ⌘-click: the tab joins or leaves the selection and anchors the next range. */
export function toggleTabSelection(id: string): void {
	const next = new Set(getSelectedTabIds());
	if (!next.delete(id)) next.add(id);
	_anchor = id;
	commit(next);
}

/**
 * ⇧-click: selects the range from the anchor to `id` in `ordered`, the sidebar's visible order. An anchor
 * or a target the list no longer holds (a closed folder's tab) selects `id` alone.
 */
export function extendTabSelection(ordered: string[], id: string): void {
	const anchor = _anchor ?? id;
	const from = ordered.indexOf(anchor);
	const to = ordered.indexOf(id);
	if (from < 0 || to < 0) {
		_anchor = id;
		commit(new Set([id]));
		return;
	}
	commit(new Set(ordered.slice(Math.min(from, to), Math.max(from, to) + 1)));
}

/**
 * A click's selection effect: ⌘ toggles, ⇧ extends the range from the anchor across `scope`, a plain
 * click collapses it. Returns whether the click selected (the caller activates the tab only then not).
 */
export function tabClickSelection(event: MouseEvent, id: string, scope: ParentNode | null): boolean {
	if (event.metaKey || event.shiftKey) {
		event.preventDefault();
		if (event.metaKey) toggleTabSelection(id);
		else extendTabSelection(visibleTabIds(scope), id);
		return true;
	}
	selectTabOnly(id);
	return false;
}

/** The tab ids in visible order inside `scope` (the Space's page or the strip), for a ⇧-click range. */
export function visibleTabIds(scope: ParentNode | null): string[] {
	return [...(scope ?? document).querySelectorAll<HTMLElement>("[data-tab-id]")].flatMap((el) => el.dataset.tabId ?? []);
}

/** The selection a tab's context menu acts on: `id` inside it keeps the set, outside collapses it. */
export function contextSelectionIds(id: string): string[] {
	if (!isTabSelected(id)) clearTabSelection();
	return [...getSelectedTabIds()];
}

/** A plain click collapses the selection; the clicked tab anchors the next range. */
export function selectTabOnly(id: string): void {
	_anchor = id;
	commit(EMPTY);
}

export function clearTabSelection(): void {
	_anchor = null;
	commit(EMPTY);
}
