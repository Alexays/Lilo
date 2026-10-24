import test from "node:test";
import assert from "node:assert/strict";
import { createStartupMarkRecorder } from "./startupMarks";

test("startup mark recorder only emits each mark once", () => {
	const events: string[] = [];
	const record = createStartupMarkRecorder((event) => {
		events.push(event);
	});

	assert.equal(record("chromeInitialStateReceived"), true);
	assert.equal(record("chromeInitialStateReceived"), false);
	assert.equal(record("chromeInitialStateApplied"), true);
	assert.deepEqual(events, [
		"chromeInitialStateReceived",
		"chromeInitialStateApplied",
	]);
});
