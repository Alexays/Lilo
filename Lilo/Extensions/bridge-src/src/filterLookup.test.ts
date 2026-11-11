// Tests for the bridge-world table lookup (FilterLookup.js) and how it reaches its page script.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { lookupFrame } from "./filterTables.testkit.ts";

const table = { "example.com": ["a"], "example.*": ["b"], "*": ["everywhere"], "other.example": ["c"] };
const location = { hostname: "www.example.com", host: "www.example.com" };

/** The page script's side: listens for its entries, then asks for them. */
function pageScript(frame: ReturnType<typeof lookupFrame>): { received: unknown[] } {
	const page = { received: [] as unknown[] };
	frame.addEventListener("__LILO_FILTER_ENTRIES__", (event) => page.received.push(JSON.parse((event as CustomEvent).detail)));
	frame.dispatchEvent(new Event("__LILO_FILTER_LOOKUP__"));
	return page;
}

describe("filter lookup", () => {
	test("a page script running after it gets the frame's entries when it asks", () => {
		const frame = lookupFrame(table, ["json-prune"], [], location);
		frame.lookup();
		assert.deepEqual(pageScript(frame).received, [{ n: "json-prune", e: ["a", "b", "everywhere"] }]);
	});

	test("a page script that ran first gets them as the lookup runs", () => {
		const frame = lookupFrame(table, ["json-prune"], [], location);
		const page = pageScript(frame);
		assert.deepEqual(page.received, []);
		frame.lookup();
		assert.deepEqual(page.received, [{ n: "json-prune", e: ["a", "b", "everywhere"] }]);
	});

	test("only the scriptlets' table has entries for every site", () => {
		const frame = lookupFrame(table, [], [], location);
		frame.lookup();
		assert.deepEqual(pageScript(frame).received, [{ n: "", e: ["a", "b"] }]);
	});

	test("a frame without entries, or under an allowlisted site, hears nothing", () => {
		const unlisted = lookupFrame({ "other.example": ["c"] }, [], [], location);
		unlisted.lookup();
		assert.deepEqual(pageScript(unlisted).received, []);
		const allowlisted = lookupFrame(table, ["json-prune"], ["example.com"], location);
		allowlisted.lookup();
		assert.deepEqual(pageScript(allowlisted).received, []);
	});
});
