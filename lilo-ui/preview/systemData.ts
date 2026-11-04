// What the Swift side answers for the system screens (History, Downloads, Process Manager, Diagnostics), with made-up data.

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;
const MB = 1024 * 1024;

function dayStart(daysAgo: number): number {
	const date = new Date();
	date.setHours(0, 0, 0, 0);
	return date.getTime() - daysAgo * DAY;
}

function at(daysAgo: number, hours: number, minutes: number): number {
	return dayStart(daysAgo) + (hours * 60 + minutes) * MINUTE;
}

function historyRows() {
	const row = (pageId: string, title: string, url: string, daysAgo: number, hours: number, minutes: number, visits = 1) => ({
		pageId, title, url, host: new URL(url).host, lastVisitAt: at(daysAgo, hours, minutes), visits, dayStart: dayStart(daysAgo),
	});
	return [
		row("p1", "Runes · Svelte docs", "https://svelte.dev/docs/svelte/what-are-runes", 0, 10, 42, 4),
		row("p2", "CSS container queries - MDN", "https://developer.mozilla.org/en-US/docs/Web/CSS/Container_queries", 0, 10, 5),
		row("p3", "Sidebar folders by a contributor · Pull Request #412", "https://github.com/acme/project/pull/412", 0, 9, 58, 3),
		row("p4", "CI · Actions run", "https://github.com/acme/project/actions", 0, 9, 54),
		row("p5", "acme/project", "https://github.com/acme/project", 0, 9, 41, 2),
		row("p6", "WebKit Features in Safari", "https://webkit.org/blog/", 0, 9, 12),
		row("p7", "Sprint board", "https://board.example.com/sprint", 0, 8, 47, 6),
		row("p8", "Weeknight recipes", "https://recipes.example.com/weeknight", 1, 18, 20),
		row("p9", "Svelte 5 migration guide", "https://svelte.dev/docs/svelte/v5-migration-guide", 1, 16, 5),
		row("p10", "Quarterly planning", "https://docs.example.com/planning", 1, 11, 47, 2),
	];
}

function downloads() {
	// Download times are epoch seconds.
	const item = (id: number, filename: string, url: string, startedAtMs: number, extra: Record<string, unknown>) => ({
		id, filename, url, startedAt: startedAtMs / 1000, bytesReceived: 0, totalBytes: 0, state: "complete", fileMissing: false, source: "wk", ...extra,
	});
	return [
		item(1, "dataset-2026.zip", "https://data.example.com/dataset-2026.zip", Date.now() - 2 * MINUTE, {
			state: "inProgress", bytesReceived: 39.1 * MB, totalBytes: 114.4 * MB, speedBytesPerSec: 1.2 * MB, eta: 120,
		}),
		item(2, "quarterly-report.pdf", "https://docs.example.com/quarterly-report.pdf", at(0, 10, 43), { bytesReceived: 2.3 * MB, totalBytes: 2.3 * MB, endedAt: at(0, 10, 43) / 1000 }),
		item(3, "cover-draft.png", "https://design.example.org/cover-draft.png", at(0, 9, 59), { bytesReceived: 3 * MB, totalBytes: 3 * MB, endedAt: at(0, 9, 59) / 1000 }),
		item(4, "onboarding-flow.fig", "https://files.example.com/onboarding-flow.fig", at(0, 8, 30), { fileMissing: true, endedAt: at(0, 8, 30) / 1000 }),
		item(5, "Setup.dmg", "https://downloads.example.com/Setup.dmg", at(1, 15, 2), { state: "interrupted", error: "The network connection was lost.", bytesReceived: 12 * MB, totalBytes: 80 * MB }),
		item(6, "harbor-at-dusk.jpg", "https://photos.example.net/harbor-at-dusk.jpg", at(1, 14, 3), { bytesReceived: 6.5 * MB, totalBytes: 6.5 * MB, endedAt: at(1, 14, 3) / 1000 }),
		item(7, "survey-results.csv", "https://forms.example.org/survey-results.csv", at(3, 11, 21), { bytesReceived: 214.8 * 1024, totalBytes: 214.8 * 1024, endedAt: at(3, 11, 21) / 1000 }),
	];
}

function processes(spaceId: string) {
	const tab = (id: string, title: string, url: string, lifecycle = "loaded-hidden", extra: Record<string, unknown> = {}) => ({
		id, spaceId, title, url, lifecycle, isAudioPlaying: false, isMicrophoneActive: false, isCameraActive: false, isScreenSharing: false, ...extra,
	});
	const web = (pid: number, bytes: number, cpu: number, tabs: unknown[], responsive = true) => ({
		id: `p${pid}`, kind: "webContent", pid, tabs, metrics: { residentSizeBytes: bytes, cpuPercent: cpu }, webProcessStateLabel: "Running", webProcessIsResponsive: responsive,
	});
	const system = (pid: number, kind: string, bytes: number, cpu: number) => ({
		id: `p${pid}`, kind, pid, tabs: [], metrics: { residentSizeBytes: bytes, cpuPercent: cpu }, webProcessStateLabel: "Running",
	});
	return {
		processes: [
			web(4310, 180 * MB, 0, [tab("tab-pr", "Sidebar folders by a contributor · Pull Request #412", "https://github.com/acme/project/pull/412")], false),
			web(4312, 824 * MB, 3.1, [
				tab("tab-runes", "Runes · Svelte docs", "https://svelte.dev/docs/svelte/what-are-runes", "active", { isAudioPlaying: true }),
				tab("tab-ci", "CI · Actions run", "https://github.com/acme/project/actions"),
			]),
			web(4320, 268 * MB, 1.4, [tab("tab-board", "Sprint board", "https://board.example.com/sprint")]),
			web(4321, 196 * MB, 0.6, [tab("tab-mail", "Inbox (3)", "https://mail.example.com/inbox")]),
			web(4322, 124 * MB, 0.2, [tab("tab-container", "CSS container queries - MDN", "https://developer.mozilla.org/en-US/docs/Web/CSS/Container_queries")]),
			system(4300, "network", 140 * MB, 2.2),
			system(4301, "gpu", 128 * MB, 6.4),
			system(4302, "provisionalWebContent", 30 * MB, 0),
			system(4303, "model", 20 * MB, 0),
		],
	};
}

function startupMetrics() {
	const launched = at(0, 9, 2) / 1000;
	const mark = (id: string, event: string, totalMilliseconds: number) => ({ id, event, timestamp: launched + totalMilliseconds / 1000, totalMilliseconds });
	return {
		summary: { bootDurationMilliseconds: 840 },
		marks: [mark("m1", "launch", 120), mark("m2", "windowShown", 300), mark("m3", "chromeReady", 540), mark("m4", "firstPaint", 840)],
		traces: [],
		lifecycleDiagnostics: {
			trackedSpaceCount: 3, activeSpaceEngineCount: 5, hiddenSpaceEngineCount: 2, totalLiveEngineCount: 7, restoringTabCount: 0,
			savedInteractionStateCount: 9, discardedOpenTabCount: 9, hiddenSpacesWithNormalRetainedEngines: 1,
		},
		perfRecordingStartedAt: null,
	};
}

function extensionDiagnostics() {
	const entry = (id: string, level: string, message: string, minutesAgo: number) => ({
		id, level, message, source: "background", extensionId: "ext-vault", timestamp: (Date.now() - minutesAgo * MINUTE) / 1000, metadata: {},
	});
	return [
		entry("d1", "error", "Service worker failed to start: script evaluation error.", 3),
		entry("d2", "error", "Unchecked runtime.lastError: The message port closed.", 12),
		entry("d3", "warning", "Content script injected late on example.com.", 20),
		entry("d4", "error", "Native messaging host not found.", 41),
	];
}

export function systemReplies(spaceId: string): Record<string, (payload: Record<string, unknown>) => Record<string, unknown>> {
	return {
		loadHistoryPage: ({ requestId }) => ({ event: "historyPage", requestId, rows: historyRows(), favicons: {} }),
		loadHistorySidebar: () => ({
			event: "historySidebar", today: 24, yesterday: 41, last7Days: 118,
			sites: [{ host: "github.com", visits: 40 }, { host: "svelte.dev", visits: 22 }, { host: "developer.mozilla.org", visits: 9 }],
			terminals: [{ openedFrom: "~/Projects/acme", visits: 4 }],
		}),
		requestDownloadsSnapshot: () => ({ event: "downloadsSnapshot", items: downloads() }),
		getProcessSnapshot: () => ({ event: "processSnapshotUpdated", ...processes(spaceId) }),
		getStartupMetrics: () => ({ event: "startupMetricsLoaded", ...startupMetrics() }),
		getExtensionDiagnostics: () => ({ event: "extensionDiagnosticsLoaded", entries: extensionDiagnostics() }),
	};
}
