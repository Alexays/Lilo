import test from "node:test";
import assert from "node:assert/strict";

(globalThis as { window?: unknown }).window ??= { __liloBootstrapEvents: [] };
type StateRune = (<T>(value: T) => T) & { raw: <T>(value: T) => T };
(globalThis as { $state?: StateRune }).$state ??= Object.assign(<T>(value: T) => value, { raw: <T>(value: T) => value });

const { neverFreezeList, withApp, withoutApp } = await import("./keepAwake.svelte");

test("an unset never-freeze setting reads as the default list", () => {
	assert.ok(neverFreezeList("").includes("com.docker.docker"));
});

test("adding and removing an app keeps the list unique", () => {
	const list = withApp(withApp(["a"], "b"), "b");
	assert.deepEqual(list, ["a", "b"]);
	assert.deepEqual(withoutApp(list, "a"), ["b"]);
});
