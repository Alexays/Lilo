import assert from "node:assert/strict";
import test from "node:test";
import { flushSync } from "svelte";
import { freshStores, stubBridgeWindow } from "./testHarness";

test("only an onboarding never finished is a first run: a replay leaves the user's Spaces alone", async () => {
	stubBridgeWindow({ document: true });
	const loadStore = await freshStores();
	const onboarding = await loadStore("/src/stores/onboarding.svelte.ts");
	onboarding.initOnboardingStore();
	const receive = (globalThis as { window: { __lilo?: { receive(msg: Record<string, unknown>): void } } }).window.__lilo!.receive;

	receive({ event: "onboardingState", show: true, step: 0, usage: "browse" });
	flushSync();
	assert.equal(onboarding.getOnboarding().firstRun, true);

	onboarding.finishOnboarding();
	receive({ event: "startOnboarding" });
	flushSync();
	assert.equal(onboarding.getOnboarding().visible, true);
	assert.equal(onboarding.getOnboarding().firstRun, false);
});
