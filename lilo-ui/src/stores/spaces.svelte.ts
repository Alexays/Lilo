import {
	on,
	type BridgeInitialStatePayload,
	type BridgeSpaceSnapshot,
} from "../lib/bridge";
import { coerceSpaceSnapshot } from "../lib/bridge/coerce";
import { resolvePendingSpaceDrop } from "./dropConfirmation.svelte";

export type SpaceState = BridgeSpaceSnapshot;

let _spaces = $state.raw<SpaceState[]>([]);
let _spaceById = $state.raw<Record<string, SpaceState>>({});
let _activeSpaceId = $state<string>("");
let _pendingSpaceTransition = $state<{
	targetId: string;
	transitionId: string;
} | null>(null);

function resolveActiveSpaceId(
	spaces: SpaceState[],
	preferredActiveSpaceId = "",
): string {
	if (
		preferredActiveSpaceId &&
		spaces.some((space) => space.id === preferredActiveSpaceId)
	) {
		return preferredActiveSpaceId;
	}

	return spaces[0]?.id ?? "";
}

function setSpaces(spaces: SpaceState[]): void {
	_spaces = spaces;
	_spaceById = Object.fromEntries(spaces.map((space) => [space.id, space]));
}

export function getSpaces(): SpaceState[] {
	return _spaces;
}

export function getActiveSpaceId(): string {
	// Every writer validates the stored id against the spaces list on assignment, so reads can
	// skip the O(spaces) re-validation scan on this hot store path.
	return _activeSpaceId;
}

export function getActiveSpace(): SpaceState | undefined {
	return _spaceById[getActiveSpaceId()];
}

export function getFocusedSpaceId(): string {
	return _pendingSpaceTransition?.targetId || _activeSpaceId;
}

export function getPendingSpaceTransition(): {
	targetId: string;
	transitionId: string;
} | null {
	return _pendingSpaceTransition;
}

export function beginSpaceTransition(
	targetId: string,
	transitionId?: string,
): void {
	_pendingSpaceTransition = {
		targetId,
		transitionId: transitionId || "",
	};
}

export function clearSpaceTransition(transitionId?: string): void {
	if (
		_pendingSpaceTransition?.transitionId &&
		transitionId &&
		_pendingSpaceTransition.transitionId !== transitionId
	) {
		return;
	}

	_pendingSpaceTransition = null;
}

export function shouldAcceptSpaceReady(
	spaceId: string,
	transitionId?: string,
): boolean {
	if (!spaceId) return false;

	if (_pendingSpaceTransition) {
		if (_pendingSpaceTransition.targetId !== spaceId) {
			return false;
		}

		if (_pendingSpaceTransition.transitionId) {
			return transitionId === _pendingSpaceTransition.transitionId;
		}

		return true;
	}

	if (!_activeSpaceId || _activeSpaceId === spaceId) return true;
	return _spaces.some((space) => space.id === spaceId);
}

export function getSpaceById(spaceId?: string): SpaceState | undefined {
	if (!spaceId) return undefined;
	return _spaceById[spaceId];
}

function sortSpaces(spaces: SpaceState[]): SpaceState[] {
	return [...spaces].sort((lhs, rhs) => lhs.sortOrder - rhs.sortOrder);
}

function patchSpace(space: BridgeSpaceSnapshot): void {
	const index = _spaces.findIndex(
		(currentSpace) => currentSpace.id === space.id,
	);
	if (index < 0) {
		return;
	}

	const nextSpace = coerceSpaceSnapshot(space);
	const nextSpaces = [..._spaces];
	const previousSpace = nextSpaces[index];
	nextSpaces[index] = { ...previousSpace, ...nextSpace };
	setSpaces(
		previousSpace.sortOrder === nextSpace.sortOrder
			? nextSpaces
			: sortSpaces(nextSpaces),
	);
}

type SpaceInitialStatePayload = Pick<
	BridgeInitialStatePayload,
	| "activeSpaceId"
	| "activeTabId"
	| "spaces"
	| "tabs"
	| "sidebarWidth"
	| "sidebarVisible"
>;

export function applySpaceInitialState(data: SpaceInitialStatePayload): void {
	const spaces = sortSpaces(data.spaces || []);
	setSpaces(spaces);
	_activeSpaceId = resolveActiveSpaceId(spaces, data.activeSpaceId || "");
	_pendingSpaceTransition = null;
}

export function initSpaceStore(): void {
	on("spaceCreated", (data) => {
		const nextSpaces = sortSpaces([..._spaces, coerceSpaceSnapshot(data)]);
		setSpaces(nextSpaces);
		_activeSpaceId = resolveActiveSpaceId(nextSpaces, _activeSpaceId);
	});

	on("spaceDeleted", (data) => {
		const nextSpaces = data.spaces
			? sortSpaces((data.spaces || []).map(coerceSpaceSnapshot))
			: _spaces.filter((space) => space.id !== data.id);

		setSpaces(nextSpaces);

		if (_pendingSpaceTransition?.targetId === data.id) {
			clearSpaceTransition();
		}

		_activeSpaceId = resolveActiveSpaceId(
			nextSpaces,
			data.activeSpaceId ?? _activeSpaceId,
		);
	});

	on("browserStateChanged", (data) => {
		if (!data.transitionId && !data.profileId) {
			return;
		}

		if (!shouldAcceptSpaceReady(data.changedSpaceId, data.transitionId)) {
			return;
		}

		_activeSpaceId = resolveActiveSpaceId(_spaces, data.changedSpaceId);
		clearSpaceTransition(data.transitionId);
	});

	on("spaceUpdated", (data) => {
		patchSpace(data);
	});

	on("spacesReordered", (data) => {
		const nextSpaces = sortSpaces((data.spaces || []).map(coerceSpaceSnapshot));
		setSpaces(nextSpaces);
		resolvePendingSpaceDrop(_spaces);
		const pendingTransition = _pendingSpaceTransition;
		if (
			pendingTransition &&
			!_spaces.some((space) => space.id === pendingTransition.targetId)
		) {
			clearSpaceTransition();
		}
		_activeSpaceId = resolveActiveSpaceId(nextSpaces, _activeSpaceId);
	});
}
