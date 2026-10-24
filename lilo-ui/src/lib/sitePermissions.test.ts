import assert from "node:assert/strict";
import test from "node:test";
import { permissionOriginFromURL, sitePermissionRows } from "./sitePermissions";
import type { BridgeSitePermissionSnapshot } from "./bridge/protocol";

function record(
	id: string,
	origin: string,
	type: string,
	decision: string,
): BridgeSitePermissionSnapshot {
	return { id, origin, type, decision, updatedAt: 0 };
}

test("permissionOriginFromURL matches the Swift origin key", () => {
	const cases: Array<[string, string]> = [
		["https://Example.com/path?q=1", "https://example.com"],
		["https://example.com:443/x", "https://example.com"],
		["http://example.com:80/", "http://example.com"],
		["https://example.com:8443/", "https://example.com:8443"],
		["http://localhost:5173/", "http://localhost:5173"],
		["about:blank", ""],
		["not a url", ""],
		["", ""],
	];
	for (const [url, expected] of cases) {
		assert.equal(permissionOriginFromURL(url), expected, url);
	}
});

test("sitePermissionRows maps stored decisions and defaults absent types to ask", () => {
	const permissions = [
		record("id-1", "https://example.com", "camera", "allow"),
		record("id-2", "https://example.com", "microphone", "deny"),
		record("id-3", "https://example.org", "location", "allow"),
	];

	assert.deepEqual(sitePermissionRows(permissions, "https://example.com"), [
		{ type: "camera", state: "allowed", id: "id-1" },
		{ type: "microphone", state: "blocked", id: "id-2" },
		{ type: "location", state: "ask" },
		{ type: "notifications", state: "ask" },
	]);

	// Another origin's records never leak in.
	assert.deepEqual(
		sitePermissionRows(permissions, "https://example.net").map((row) => row.state),
		["ask", "ask", "ask", "ask"],
	);
});
