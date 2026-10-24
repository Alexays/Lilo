import test from "node:test";
import assert from "node:assert/strict";
import { resolveTabCloseIntent } from "./tabCloseBehavior";

test("resolveTabCloseIntent closes an open pinned tab first", () => {
	assert.equal(
		resolveTabCloseIntent({
			isClosed: false,
			isPinned: true,
			isBookmarked: false,
		}),
		"close",
	);
});

test("resolveTabCloseIntent unpins a closed pinned tab", () => {
	assert.equal(
		resolveTabCloseIntent({
			isClosed: true,
			isPinned: true,
			isBookmarked: false,
		}),
		"unpin",
	);
});
