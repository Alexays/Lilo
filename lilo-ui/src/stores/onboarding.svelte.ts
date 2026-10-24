// Critical store: `onboardingState` is pushed right after the initial state, before the lazily
// mounted shell exists, and the bridge has no replay.

import { on } from "../lib/bridge";
import { importActions, onboardingActions, settingsActions } from "../lib/bridge/actions";
import type { ImportProgress, ImportSourceInfo, ImportSummaryItem } from "../lib/bridge/protocol";
import { setSetting } from "./settings.svelte";
import { isCommandBarOpen, openCommandBar } from "./commandBar.svelte";
import { getActiveTab, isBlankTab } from "./tabs.svelte";
import { hideDefaultBrowserInvite } from "./urlBarDrawer.svelte";
import {
	buildImportSelections,
	defaultImportChoices,
	importPlan,
	onboardingSteps,
	resumeStep,
	type ImportChoices,
	type ImportPhase,
	type OnboardingUsage,
} from "../components/onboarding/onboardingModel";

/** "full" is the onboarding; the others are that screen alone, opened from Settings. */
type OnboardingMode = "full" | "import" | "passwords";

const state = $state({
	visible: false,
	mode: "full" as OnboardingMode,
	usage: "browse" as OnboardingUsage,
	step: 0,
	collapsed: false,
});

const importState = $state({
	sources: null as ImportSourceInfo[] | null,
	choices: { profiles: [], kinds: [], extensionIds: [] } as ImportChoices,
	running: false,
	/** What the running import will do, and the latest step native reported. */
	plan: [] as ImportPhase[],
	progress: null as ImportProgress | null,
	summary: null as ImportSummaryItem[] | null,
});

function setStep(step: number): void {
	state.step = step;
	if (state.mode === "full") onboardingActions.setStep(step);
}

export function initOnboardingStore(): void {
	on("onboardingState", (data) => {
		if (!data.show) return;
		state.visible = true;
		state.mode = "full";
		state.usage = data.usage === "develop" ? "develop" : "browse";
		state.step = resumeStep(data.step, state.usage);
		importActions.scan();
		settingsActions.loadDefaultBrowserStatus();
	});
	on("startOnboarding", () => startOnboarding("full"));
	on("importSourcesLoaded", (data) => {
		// A browser unlocked by Full Disk Access comes back preselected when nothing else was chosen.
		const fresh = importState.sources === null || importState.choices.profiles.length === 0;
		importState.sources = data.sources;
		if (fresh) importState.choices = defaultImportChoices(data.sources);
	});
	on("importProgress", (data) => {
		if (importState.running) importState.progress = data;
	});
	on("importFinished", (data) => {
		importState.running = false;
		importState.summary = data.summary;
	});
	onboardingActions.load();
}

export function getOnboarding() {
	return state;
}

export function getImportState() {
	return importState;
}

export function startOnboarding(mode: OnboardingMode = "full"): void {
	state.visible = true;
	state.collapsed = false;
	state.mode = mode;
	state.step = mode === "full" ? 0 : onboardingSteps(state.usage).indexOf(mode);
	// A fresh scan recomputes the default choices; a previous run's results must not linger.
	importState.sources = null;
	importState.progress = null;
	importState.summary = null;
	importActions.scan();
	settingsActions.loadDefaultBrowserStatus();
}

export function goNext(): void {
	if (state.mode !== "full") return finishOnboarding();
	setStep(Math.min(state.step + 1, onboardingSteps(state.usage).length - 1));
}

/** The usage also decides whether the terminal and AI agents are on. */
export function setUsage(usage: OnboardingUsage): void {
	state.usage = usage;
	settingsActions.set("onboardingUsage", usage);
	const develop = usage === "develop" ? "true" : "false";
	setSetting("terminalEnabled", develop);
	setSetting("agentControlEnabled", develop);
}

export function goBack(): void {
	setStep(Math.max(state.step - 1, 1));
}

/** A link opened from another app while the intro shows: reveal the page behind the card. */
export function noteExternalNavigation(): void {
	if (state.visible && state.step === 0) setStep(1);
}

export function finishOnboarding(): void {
	// Native keeps the scanned sources (and rescans on app activation) until told the page is gone.
	importActions.close();
	if (state.mode === "full") {
		onboardingActions.complete();
		// Completion marks the invite as prompted: hidden here, it never shows once the card is gone.
		hideDefaultBrowserInvite();
		// Native holds the blank tab's command bar while the onboarding shows.
		if (isBlankTab(getActiveTab()) && !isCommandBarOpen()) openCommandBar("", "default", true);
	}
	state.visible = false;
}

export function collapseOnboarding(): void {
	state.collapsed = true;
}

export function expandOnboarding(): void {
	state.collapsed = false;
}

export function setImportChoices(choices: ImportChoices): void {
	importState.choices = choices;
}

export function runSelectedImport(): void {
	if (!importState.sources || importState.running) return;
	const selections = buildImportSelections(importState.sources, importState.choices);
	if (selections.length === 0) return goNext();
	importState.running = true;
	importState.plan = importPlan(selections);
	importState.progress = null;
	importState.summary = null;
	importActions.run(selections);
}
