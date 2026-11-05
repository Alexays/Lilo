import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { ImportKind, ImportSourceInfo } from "../../lib/bridge/protocol";
import {
	buildImportSelections,
	defaultImportChoices,
	importPlan,
	importStatus,
	onboardingSteps,
	PASSWORD_MANAGERS,
	resumeStep,
	toggleSource,
} from "./onboardingModel";

describe("onboarding steps", () => {
	it("resumes on a question, never at the arrival", () => {
		assert.equal(resumeStep(0, "browse"), 0);
		assert.equal(resumeStep(2, "browse"), 2);
		assert.equal(onboardingSteps("browse")[resumeStep(99, "browse")], "yourLilo");
		assert.equal(onboardingSteps("develop")[resumeStep(99, "develop")], "agents");
		assert.equal(resumeStep(-4, "browse"), 1);
		assert.equal(resumeStep(Number.NaN, "browse"), 1);
	});

	it("asks one question per screen, the agents only on their path", () => {
		assert.deepEqual(onboardingSteps("browse"), ["intro", "usage", "import", "yourLilo", "arrival"]);
		assert.deepEqual(onboardingSteps("agents"), ["intro", "usage", "import", "yourLilo", "agents", "arrival"]);
		assert.deepEqual(onboardingSteps("develop"), onboardingSteps("agents"));
	});
});

describe("password managers", () => {
	it("lists store extensions by id and iCloud Passwords as the one to come", () => {
		for (const manager of PASSWORD_MANAGERS) assert.match(manager.id, /^[a-p]{32}$/);
		assert.deepEqual(PASSWORD_MANAGERS.filter((manager) => manager.soon).map((manager) => manager.key), ["iCloud"]);
		assert.equal(PASSWORD_MANAGERS[0]?.soon, true);
	});
});

const sources: ImportSourceInfo[] = [
	{ id: "chrome", name: "Chrome", family: "chromium", iconDataURL: "", needsFullDiskAccess: false, profiles: [
		{ id: "Default", name: "Perso", kinds: ["bookmarks", "history", "cookies", "extensions"], extensions: [{ id: "e1", name: "Blocker" }] },
		{ id: "Profile 1", name: "Travail", kinds: ["bookmarks"], extensions: [] },
	] },
	{ id: "safari", name: "Safari", family: "safari", iconDataURL: "", needsFullDiskAccess: true, profiles: [
		{ id: "safari", name: "Safari", kinds: ["bookmarks", "history"], extensions: [] },
	] },
];

describe("import selections", () => {
	it("preselects only the first readable source, with its extensions", () => {
		assert.deepEqual(defaultImportChoices(sources), {
			profiles: ["chrome/Default"],
			kinds: ["bookmarks", "tabs", "history", "cookies", "extensions"],
			extensionIds: ["e1"],
		});
	});

	it("never preselects a second browser, which would create another Lilo profile", () => {
		const two: ImportSourceInfo[] = [
			{ id: "arc", name: "Arc", family: "chromium", iconDataURL: "", needsFullDiskAccess: false, profiles: [{ id: "Default", name: "Default", kinds: ["bookmarks"], extensions: [] }] },
			...sources,
		];
		assert.deepEqual(defaultImportChoices(two).profiles, ["arc/Default"]);
	});

	it("keeps only kinds the profile has and drops empty selections", () => {
		const selections = buildImportSelections(sources, { profiles: ["chrome/Default", "chrome/Profile 1"], kinds: ["history"], extensionIds: [] });
		assert.deepEqual(selections, [{ sourceId: "chrome", profileId: "Default", kinds: ["history"], extensionIds: [] }]);
	});

	it("a browser card toggles its first profile and that browser's extensions", () => {
		const chrome = sources[0];
		const off = toggleSource(chrome, defaultImportChoices(sources));
		assert.deepEqual(off.profiles, []);
		assert.deepEqual(off.extensionIds, []);
		const on = toggleSource(chrome, off);
		assert.deepEqual(on.profiles, ["chrome/Default"]);
		assert.deepEqual(on.extensionIds, ["e1"]);
	});
});

describe("import progress", () => {
	const plan = importPlan([
		{ sourceId: "chrome", profileId: "Default", kinds: ["history", "bookmarks", "extensions"], extensionIds: ["e1", "e2", "e3"] },
		{ sourceId: "chrome", profileId: "Profile 1", kinds: ["cookies", "extensions"], extensionIds: [] },
	]);
	const at = (profileId: string, kind: ImportKind, done = 0, total = 0) => importStatus(plan, { sourceId: "chrome", profileId, kind, done, total });

	it("runs each profile's kinds in native order, extensions weighed per install, none when none is chosen", () => {
		assert.deepEqual(plan.map((phase) => `${phase.profileId} ${phase.kind} ${phase.weight}`), [
			"Default bookmarks 1", "Default history 2", "Default extensions 6", "Profile 1 cookies 1",
		]);
	});

	it("counts the phases before the running one, and never reaches the end before the import finished", () => {
		assert.deepEqual(importStatus(plan, null), { fraction: 0, indeterminate: true, phase: plan[0] });
		assert.equal(at("Default", "history").fraction, 1 / 10);
		assert.equal(at("Default", "extensions", 2, 3).fraction, (3 + 4) / 10);
		assert.equal(at("Default", "extensions", 2, 3).indeterminate, false);
		const last = at("Profile 1", "cookies");
		assert.equal(last.fraction, 9 / 10);
		assert.equal(last.indeterminate, true);
		assert.ok(at("Default", "extensions", 3, 3).fraction < (3 + 6) / 10, "an install under way is not done");
	});
});
