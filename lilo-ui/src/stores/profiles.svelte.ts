import {
	type BridgeInitialStatePayload,
	type BridgeProfileSnapshot,
	on,
} from "../lib/bridge";
import { coerceProfileSnapshot } from "../lib/bridge/coerce";
import {
	getFocusedSpaceId,
	getSpaceById,
	shouldAcceptSpaceReady,
} from "./spaces.svelte";

type ProfileState = BridgeProfileSnapshot;

let _profiles = $state.raw<ProfileState[]>([]);
let _profileById = $state.raw<Record<string, ProfileState>>({});
let _activeProfileId = $state<string>("");
let _extensionCounts = $state.raw<Record<string, number> | null>(null);

function setProfiles(profiles: ProfileState[]): void {
	_profiles = profiles;
	_profileById = Object.fromEntries(
		profiles.map((profile) => [profile.id, profile]),
	);
}

export function getProfiles(): ProfileState[] {
	return _profiles;
}

export function getProfileById(id?: string): ProfileState | undefined {
	if (!id) return undefined;
	return _profileById[id];
}

/** Installed extensions per profile id, null until `profileActions.loadStats()` answers. */
export function getProfileExtensionCounts(): Record<string, number> | null {
	return _extensionCounts;
}

export function getActiveProfileId(): string {
	return _activeProfileId;
}

function sortProfiles(profiles: ProfileState[]): ProfileState[] {
	return [...profiles].sort((lhs, rhs) =>
		lhs.name.localeCompare(rhs.name, undefined, { sensitivity: "base" }),
	);
}

function patchProfile(profile: BridgeProfileSnapshot): void {
	const index = _profiles.findIndex(
		(currentProfile) => currentProfile.id === profile.id,
	);
	if (index < 0) {
		return;
	}

	const nextProfile = coerceProfileSnapshot(profile);
	const nextProfiles = [..._profiles];
	const previousProfile = nextProfiles[index];
	nextProfiles[index] = { ...previousProfile, ...nextProfile };
	setProfiles(
		previousProfile.name.localeCompare(nextProfile.name, undefined, {
			sensitivity: "base",
		}) === 0
			? nextProfiles
			: sortProfiles(nextProfiles),
	);
}

export function applyProfileInitialState(
	data: BridgeInitialStatePayload,
): void {
	setProfiles(sortProfiles(data.profiles || []));
	_activeProfileId = data.activeProfileId || "";
}

export function initProfileStore(): void {
	on("profileCreated", (data) => {
		setProfiles(sortProfiles([..._profiles, coerceProfileSnapshot(data)]));
	});

	on("profileDeleted", (data) => {
		setProfiles(_profiles.filter((p) => p.id !== data.id));
	});

	on("profileActivated", (data) => {
		const focusSpaceId = getFocusedSpaceId();
		const focusProfileId = getSpaceById(focusSpaceId)?.profileId;
		if (focusProfileId && focusProfileId !== data.id) {
			return;
		}

		_activeProfileId = data.id;
	});

	on("browserStateChanged", (data) => {
		if (!data.transitionId && !data.profileId) {
			return;
		}

		if (!shouldAcceptSpaceReady(data.changedSpaceId, data.transitionId)) {
			return;
		}

		const profileId = data.profileId || getSpaceById(data.changedSpaceId)?.profileId;
		if (profileId) {
			_activeProfileId = profileId;
		}
	});

	on("profileUpdated", (data) => {
		patchProfile(data);
	});

	on("profileStats", (data) => {
		_extensionCounts = data.extensionCounts;
	});
}
