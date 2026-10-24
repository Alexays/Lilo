import assert from "node:assert/strict";
import test from "node:test";

import type {
	BridgeExtensionDiagnosticSnapshot,
	BridgeStartupTraceSnapshot,
} from "../../lib/bridge/protocol";
import { filterLog, formatEventName, logEntries, startupWaterfall } from "./diagnosticsPanelModel";

function mark(id: string, totalMilliseconds: number, deltaMilliseconds: number) {
	return { id, timestamp: 0, event: id, totalMilliseconds, deltaMilliseconds };
}

function extensionEntry(partial: Partial<BridgeExtensionDiagnosticSnapshot>): BridgeExtensionDiagnosticSnapshot {
	return {
		id: "1",
		timestamp: 0,
		level: "info",
		source: "",
		extensionId: "ublock",
		message: "message",
		metadata: {},
		...partial,
	};
}

function trace(partial: Partial<BridgeStartupTraceSnapshot>): BridgeStartupTraceSnapshot {
	return { id: "1", timestamp: 0, category: "lifecycle", message: "trace", totalMilliseconds: 12, ...partial };
}

const label = (id: string): string => (id ? id.toUpperCase() : "App");

test("formatEventName splits camelCase, acronyms and underscores", () => {
	assert.equal(formatEventName("chromeReady"), "Chrome Ready");
	assert.equal(formatEventName("loadURLRequest"), "Load URL Request");
	assert.equal(formatEventName("store_loaded"), "Store loaded");
});

test("startupWaterfall places each step on the boot timeline and flags the slowest", () => {
	const rows = startupWaterfall([mark("start", 20, 20), mark("store", 100, 80), mark("ready", 200, 100)]);

	assert.deepEqual(
		rows.map((row) => [row.id, row.startPct, row.widthPct, row.slowest]),
		[
			["start", 0, 10, false],
			["store", 10, 40, false],
			["ready", 50, 50, true],
		],
	);
	assert.deepEqual(startupWaterfall([]), []);
});

test("logEntries merges extension logs and traces newest first, labelling extensions", () => {
	const entries = logEntries(
		[
			extensionEntry({ id: "a", timestamp: 10, level: "error", source: "dnr", metadata: { rule: "4021", tab: "" } }),
			extensionEntry({ id: "b", timestamp: 30, extensionId: "" }),
		],
		[trace({ id: "t", timestamp: 20 })],
		label,
	);

	assert.deepEqual(
		entries.map((entry) => [entry.id, entry.title, entry.message, entry.detail, entry.durationMs]),
		[
			["ext-b", "App", "message", null, null],
			["trace-t", "lifecycle", "trace", null, 12],
			["ext-a", "UBLOCK", "[dnr] message", "rule: 4021", null],
		],
	);
});

test("filterLog narrows by kind, level and query over title, message and detail", () => {
	const entries = logEntries(
		[
			extensionEntry({ id: "err", level: "error", message: "invalid regexFilter" }),
			extensionEntry({ id: "warn", level: "warning", extensionId: "onepassword", metadata: { port: "native" } }),
		],
		[trace({ id: "trim", message: "trim discarded 4 engines" })],
		label,
	);
	const ids = (filter: Parameters<typeof filterLog>[1], query = "") =>
		filterLog(entries, filter, query).map((entry) => entry.id);

	assert.deepEqual(ids("errors"), ["ext-err"]);
	assert.deepEqual(ids("extensions"), ["ext-err", "ext-warn"]);
	assert.deepEqual(ids("traces"), ["trace-trim"]);
	assert.deepEqual(ids("all", "REGEX"), ["ext-err"]);
	assert.deepEqual(ids("all", "onepassword"), ["ext-warn"]);
	assert.deepEqual(ids("all", "native"), ["ext-warn"]);
});
