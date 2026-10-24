import assert from "node:assert/strict";
import test from "node:test";
import type {
	BridgeProcessInfo,
	BridgeProcessTabInfo,
} from "../../lib/bridge/protocol";
import { filterTabUsages, processOverview } from "./processManagerModel";

const MB = 1024 ** 2;

function process(partial: Partial<BridgeProcessInfo>): BridgeProcessInfo {
	return {
		id: `${partial.kind ?? "webContent"}-${partial.pid ?? 1}`,
		kind: "webContent",
		pid: 1,
		tabs: [],
		metrics: null,
		webProcessStateLabel: "state-0",
		webProcessIsResponsive: null,
		...partial,
	};
}

function tab(partial: Partial<BridgeProcessTabInfo>): BridgeProcessTabInfo {
	return {
		id: "tab",
		spaceId: "space",
		title: "Tab",
		url: "https://example.com",
		lifecycle: "active",
		isAudioPlaying: false,
		isMicrophoneActive: false,
		isCameraActive: false,
		isScreenSharing: false,
		...partial,
	};
}

function metrics(megabytes: number, cpuPercent = 0): BridgeProcessInfo["metrics"] {
	return { residentSizeBytes: megabytes * MB, cpuPercent };
}

test("splits a process's memory across its tabs and sorts unresponsive tabs first, then by memory", () => {
	const overview = processOverview({
		processes: [
			process({ pid: 1, tabs: [tab({ id: "a" }), tab({ id: "b" })], metrics: metrics(400, 2) }),
			process({ pid: 2, tabs: [tab({ id: "c" })], metrics: metrics(300, 3) }),
			process({ pid: 3, tabs: [tab({ id: "d" })], metrics: metrics(50), webProcessIsResponsive: false }),
			process({ kind: "gpu", pid: 4, metrics: metrics(100, 5) }),
			process({ pid: 5, metrics: metrics(20) }),
		],
	});

	assert.deepEqual(
		overview.tabs.map((usage) => [usage.tab.id, usage.bytes / MB, usage.shared, usage.unresponsive]),
		[
			["d", 50, false, true],
			["c", 300, false, false],
			["a", 200, true, false],
			["b", 200, true, false],
		],
	);
	assert.deepEqual(overview.system.map((p) => p.pid), [4, 5]);
	assert.equal(overview.systemBytes, 120 * MB);
	assert.equal(overview.totalBytes, 870 * MB);
	assert.equal(overview.cpuPercent, 10);
});

test("names the three largest tabs in the memory bar and folds the rest", () => {
	const overview = processOverview({
		processes: [100, 400, 300, 200, 50].map((mb, index) =>
			process({ pid: index + 1, tabs: [tab({ id: `t${index}`, title: `T${index}` })], metrics: metrics(mb) }),
		).concat(process({ kind: "network", pid: 9, metrics: metrics(30) })),
	});

	assert.deepEqual(
		overview.segments.map((segment) => [segment.id, segment.label, segment.bytes / MB]),
		[
			["t1", "T1", 400],
			["t2", "T2", 300],
			["t3", "T3", 200],
			["others", null, 150],
			["system", null, 30],
		],
	);
});

test("reclaims hidden idle tabs, counting memory only for processes that empty out", () => {
	const overview = processOverview({
		processes: [
			process({ pid: 1, tabs: [tab({ id: "hidden", lifecycle: "loaded-hidden" })], metrics: metrics(300) }),
			process({ pid: 2, tabs: [tab({ id: "frozen", lifecycle: "frozen" })], metrics: metrics(100) }),
			process({ pid: 3, tabs: [tab({ id: "music", lifecycle: "loaded-hidden", isAudioPlaying: true })], metrics: metrics(200) }),
			process({
				pid: 4,
				tabs: [tab({ id: "visible" }), tab({ id: "sibling", lifecycle: "loaded-hidden" })],
				metrics: metrics(500),
			}),
		],
	});

	assert.equal(overview.reclaimableTabCount, 3);
	assert.equal(overview.reclaimableBytes, 400 * MB);
});

test("an empty snapshot yields an empty overview", () => {
	const overview = processOverview(null);
	assert.equal(overview.totalBytes, 0);
	assert.deepEqual(overview.tabs, []);
	assert.deepEqual(overview.segments, []);
	assert.equal(overview.reclaimableTabCount, 0);
});

test("filterTabUsages matches title and url, case-insensitively", () => {
	const { tabs } = processOverview({
		processes: [
			process({ pid: 1, tabs: [tab({ id: "mail", title: "Inbox", url: "https://mail.example.com" })], metrics: metrics(10) }),
			process({ pid: 2, tabs: [tab({ id: "docs", title: "Roadmap", url: "https://docs.example.com" })], metrics: metrics(20) }),
		],
	});

	assert.deepEqual(filterTabUsages(tabs, "").map((usage) => usage.tab.id), ["docs", "mail"]);
	assert.deepEqual(filterTabUsages(tabs, "INBOX").map((usage) => usage.tab.id), ["mail"]);
	assert.deepEqual(filterTabUsages(tabs, "docs.example").map((usage) => usage.tab.id), ["docs"]);
});
