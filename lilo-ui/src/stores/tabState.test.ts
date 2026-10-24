import test from "node:test";
import assert from "node:assert/strict";
import {
	resolveActiveTabId,
	type TabStateLike,
} from "./tabState";

interface TestTab extends TabStateLike {
	title: string;
}

test("resolveActiveTabId ignores closed preferred tabs", () => {
	const tabs: TestTab[] = [
		{ id: "bookmark", isClosed: true, title: "Bookmark" },
		{ id: "open", isClosed: false, title: "Open" },
	];

	assert.equal(resolveActiveTabId(tabs, "bookmark", "open"), "open");
});
