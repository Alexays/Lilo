import type { ImportKind, ImportSelection, ImportSourceInfo } from "../../lib/bridge/protocol";

export type OnboardingUsage = "browse" | "develop";
type OnboardingStep = "intro" | "usage" | "import" | "passwords" | "appearance" | "essentials" | "agents" | "tips" | "arrival";

// Both paths share their steps up to the essentials, so a saved index means the same screen in either.
const BROWSE_STEPS: readonly OnboardingStep[] = ["intro", "usage", "import", "passwords", "appearance", "essentials", "tips", "arrival"];
const DEVELOP_STEPS: readonly OnboardingStep[] = ["intro", "usage", "import", "passwords", "appearance", "essentials", "agents", "tips", "arrival"];

export function onboardingSteps(usage: OnboardingUsage): readonly OnboardingStep[] {
	return usage === "develop" ? DEVELOP_STEPS : BROWSE_STEPS;
}

/** A relaunch resumes inside the card: never the intro again, never straight to the arrival. */
export function resumeStep(saved: number, usage: OnboardingUsage): number {
	if (!Number.isInteger(saved) || saved < 1) return saved === 0 ? 0 : 1;
	return Math.min(saved, onboardingSteps(usage).length - 2);
}

interface PasswordManager {
	/** Names its line under `onboarding.passwords.managers`. */
	key: string;
	/** Chrome Web Store id. */
	id: string;
	name: string;
	/** Shown, but not installable yet. */
	soon?: boolean;
}

/** Managers whose store extension installs, starts and opens its popup in the store smoke test (make ext-smoke),
 * after iCloud Passwords, by store user count. */
export const PASSWORD_MANAGERS: readonly PasswordManager[] = [
	// Its native helper only answers browsers holding an entitlement Apple has yet to grant Lilo.
	{ key: "iCloud", id: "pejdijmoenmkgeppbflobdenhhabjlaj", name: "iCloud Passwords", soon: true },
	{ key: "nordPass", id: "eiaeiblijfjekdanodkjadfinkhbfgcd", name: "NordPass" },
	{ key: "bitwarden", id: "nngceckbapebfimnlniiiahkandclblb", name: "Bitwarden" },
	{ key: "onePassword", id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa", name: "1Password" },
	{ key: "protonPass", id: "ghmbeldphafepmbegfdlkpapadhbakde", name: "Proton Pass" },
	{ key: "dashlane", id: "fdjamakpfbbddfjaooikfcpapjohcfmg", name: "Dashlane" },
	{ key: "keePassXC", id: "oboonakemofpalcgghocfoadofidjkkk", name: "KeePassXC" },
];

export interface ImportChoices {
	/** `${sourceId}/${profileId}` of each profile to import. */
	profiles: string[];
	kinds: ImportKind[];
	/** Extension ids the user kept checked. */
	extensionIds: string[];
}

export function profileKey(sourceId: string, profileId: string): string {
	return `${sourceId}/${profileId}`;
}

/**
 * Only the first readable source's first profile is preselected: it lands in the active Lilo
 * profile, while each extra profile would create a new one (and a Keychain prompt per browser).
 */
export function defaultImportChoices(sources: ImportSourceInfo[]): ImportChoices {
	const source = sources.find((candidate) => !candidate.needsFullDiskAccess);
	const firstProfile = source ? source.profiles.slice(0, 1).map((profile) => ({ source, profile })) : [];
	return {
		profiles: firstProfile.map(({ source, profile }) => profileKey(source.id, profile.id)),
		kinds: ["bookmarks", "tabs", "history", "cookies", "extensions"],
		extensionIds: firstProfile.flatMap(({ profile }) => profile.extensions.map((ext) => ext.id)),
	};
}

/** One selection per chosen profile, limited to what that profile actually has. */
export function buildImportSelections(sources: ImportSourceInfo[], choices: ImportChoices): ImportSelection[] {
	return sources.flatMap((source) =>
		source.profiles
			.filter((profile) => choices.profiles.includes(profileKey(source.id, profile.id)))
			.map((profile) => ({
				sourceId: source.id,
				profileId: profile.id,
				kinds: profile.kinds.filter((kind) => choices.kinds.includes(kind)),
				extensionIds: profile.extensions.map((ext) => ext.id).filter((id) => choices.extensionIds.includes(id)),
			}))
			.filter((selection) => selection.kinds.length > 0),
	);
}

/** A browser card is on when any of its profiles is chosen; turning it on picks its first profile. */
export function toggleSource(source: ImportSourceInfo, choices: ImportChoices): ImportChoices {
	const keys = source.profiles.map((profile) => profileKey(source.id, profile.id));
	const on = keys.some((key) => choices.profiles.includes(key));
	if (on) {
		const extensionIds = new Set(source.profiles.flatMap((profile) => profile.extensions.map((ext) => ext.id)));
		return {
			...choices,
			profiles: choices.profiles.filter((key) => !keys.includes(key)),
			extensionIds: choices.extensionIds.filter((id) => !extensionIds.has(id)),
		};
	}
	const first = source.profiles[0];
	if (!first) return choices;
	return {
		...choices,
		profiles: [...choices.profiles, keys[0]],
		extensionIds: [...choices.extensionIds, ...first.extensions.map((ext) => ext.id)],
	};
}
