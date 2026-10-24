import assert from "node:assert/strict";
import test from "node:test";

// This suite runs under plain Node (no jsdom), where EventTarget is a real global: a fake window/document is enough.
function installFakeDom(): {
	window: EventTarget;
	document: EventTarget & { visibilityState: string };
} {
	const win = new EventTarget();
	const doc = new EventTarget() as EventTarget & { visibilityState: string };
	doc.visibilityState = "visible";
	Object.assign(globalThis, { window: win, document: doc });
	return { window: win, document: doc };
}

test("clearAllHover fires onClear for every subscriber", async () => {
	installFakeDom();
	const { subscribeHoverClear, clearAllHover } = await import("./hoverClear");

	let clearedA = 0;
	let clearedB = 0;
	const unsubA = subscribeHoverClear(() => {
		clearedA++;
	});
	const unsubB = subscribeHoverClear(() => {
		clearedB++;
	});

	clearAllHover();

	assert.equal(clearedA, 1);
	assert.equal(clearedB, 1);

	unsubA();
	unsubB();
});

test("a chrome DOM blur does not clear hover (content view taking first responder)", async () => {
	const { window } = installFakeDom();
	const { subscribeHoverClear } = await import("./hoverClear");

	let cleared = 0;
	const unsub = subscribeHoverClear(() => {
		cleared++;
	});

	// The chrome page blurs on every tab activation (the content WebView takes the native first
	// responder while the window stays key and the pointer never moves). Clearing hover here would
	// leave the row under the cursor stuck "unhovered" until the pointer left and came back.
	window.dispatchEvent(new Event("blur"));

	assert.equal(cleared, 0);

	unsub();
});

test("clears hover when the document becomes hidden, not while it stays visible", async () => {
	const { document } = installFakeDom();
	const { subscribeHoverClear } = await import("./hoverClear");

	let cleared = 0;
	const unsub = subscribeHoverClear(() => {
		cleared++;
	});

	document.visibilityState = "visible";
	document.dispatchEvent(new Event("visibilitychange"));
	assert.equal(cleared, 0);

	document.visibilityState = "hidden";
	document.dispatchEvent(new Event("visibilitychange"));
	assert.equal(cleared, 1);

	unsub();
});

test("only notifies dnd-opted-in subscribers on lilo-sidebar-dnd-active-change", async () => {
	const { document } = installFakeDom();
	const { subscribeHoverClear } = await import("./hoverClear");

	let optedIn = 0;
	let optedOut = 0;
	const unsubIn = subscribeHoverClear(
		() => {
			optedIn++;
		},
		{ reactToDndActiveChange: true },
	);
	const unsubOut = subscribeHoverClear(() => {
		optedOut++;
	});

	document.dispatchEvent(new Event("lilo-sidebar-dnd-active-change"));

	assert.equal(optedIn, 1);
	assert.equal(optedOut, 0);

	unsubIn();
	unsubOut();
});

test("an unsubscribed callback no longer fires", async () => {
	const { document } = installFakeDom();
	const { subscribeHoverClear, clearAllHover } = await import("./hoverClear");

	let clearedA = 0;
	let clearedB = 0;
	const unsubA = subscribeHoverClear(() => {
		clearedA++;
	});
	const unsubB = subscribeHoverClear(() => {
		clearedB++;
	});

	unsubA();
	clearAllHover();
	assert.equal(clearedA, 0);
	assert.equal(clearedB, 1);

	unsubB();
	document.visibilityState = "hidden";
	document.dispatchEvent(new Event("visibilitychange"));
	assert.equal(clearedB, 1);
});
