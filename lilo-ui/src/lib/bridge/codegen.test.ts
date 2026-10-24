import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, "../../../../");

// Import the pure generator functions (no file I/O side effects)
const { generateTS, generateSwift } = await import(
	pathToFileURL(resolve(root, "scripts/generate_bridge_protocol.mjs")).href
);

const schema = JSON.parse(readFileSync(resolve(root, "bridge-schema/tab.json"), "utf8"));
const fields = schema.fields;

test("generated TS file is up-to-date with bridge-schema/tab.json", () => {
	const generated = generateTS(fields);
	const checkedIn = readFileSync(
		resolve(__dirname, "tabProtocol.gen.ts"),
		"utf8",
	);
	assert.equal(
		checkedIn,
		generated,
		"tabProtocol.gen.ts is out of date. Run: make bridge-gen",
	);
});

test("generated Swift file is up-to-date with bridge-schema/tab.json", () => {
	const generated = generateSwift(fields);
	const checkedIn = readFileSync(
		resolve(root, "Lilo/Generated/TabBridgeSchema.gen.swift"),
		"utf8",
	);
	assert.equal(
		checkedIn,
		generated,
		"TabBridgeSchema.gen.swift is out of date. Run: make bridge-gen",
	);
});

test("every snapshot field the host may leave out at its default coerces back to that default", async () => {
	// Tab.snapshotData drops fields at false, 0 or "", except these.
	const alwaysSent = new Set(["id", "url", "title", "faviconDataURL", "faviconDominantColor"]);
	const { coerceTabSnapshot } = await import("./tabProtocol.gen");
	const sparse = coerceTabSnapshot({ id: "a", url: "", title: "" }) as unknown as Record<string, unknown>;
	for (const field of fields as { name: string; type: string; tsDefault?: string; tsOptional?: boolean }[]) {
		if (alwaysSent.has(field.name)) continue;
		const value = sparse[field.name];
		const ok = value === undefined || value === false || value === 0 || value === "" || field.name === "kind";
		assert.ok(ok, `${field.name} coerces a missing value to ${String(value)}, not its default`);
	}
});

test("terminal fields default for web tabs and pass through for terminals", async () => {
	const { coerceTabSnapshot } = await import("./tabProtocol.gen");
	const web = coerceTabSnapshot({ id: "a", url: "https://example.com", title: "Example" });
	assert.equal(web.kind, "web");
	assert.equal(web.terminalState, "");
	assert.equal(web.hasUnreadOutput, false);

	const terminal = coerceTabSnapshot({
		id: "b", url: "", title: "Lilo", kind: "terminal", cwd: "/tmp", terminalState: "busy", hasUnreadOutput: true,
	});
	assert.equal(terminal.kind, "terminal");
	assert.equal(terminal.cwd, "/tmp");
	assert.equal(terminal.terminalState, "busy");
	assert.equal(terminal.hasUnreadOutput, true);
});
