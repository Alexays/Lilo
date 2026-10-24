import type {
	BridgeProcessInfo,
	BridgeProcessSnapshot,
	BridgeProcessTabInfo,
} from "../../lib/bridge/protocol";

interface TabUsage {
	tab: BridgeProcessTabInfo;
	process: BridgeProcessInfo;
	/** The process's resident size split evenly across the tabs it hosts. */
	bytes: number;
	/** True when the process hosts several tabs, so `bytes` is an estimate. */
	shared: boolean;
	unresponsive: boolean;
}

interface MemorySegment {
	/** Tab id, or "others" / "system". */
	id: string;
	label: string | null;
	bytes: number;
}

interface ProcessOverview {
	totalBytes: number;
	cpuPercent: number;
	/** Unresponsive tabs first, then by memory, largest first. */
	tabs: TabUsage[];
	/** Network, GPU, model, provisional and tab-less content processes. */
	system: BridgeProcessInfo[];
	systemBytes: number;
	segments: MemorySegment[];
	reclaimableTabCount: number;
	reclaimableBytes: number;
}

const NAMED_SEGMENTS = 3;

function isHiddenAndIdle(tab: BridgeProcessTabInfo): boolean {
	return (
		(tab.lifecycle === "loaded-hidden" || tab.lifecycle === "frozen") &&
		!tab.isAudioPlaying &&
		!tab.isMicrophoneActive &&
		!tab.isCameraActive &&
		!tab.isScreenSharing &&
		!tab.isPictureInPictureActive
	);
}

export function processOverview(snapshot: BridgeProcessSnapshot | null): ProcessOverview {
	const tabs: TabUsage[] = [];
	const system: BridgeProcessInfo[] = [];
	let systemBytes = 0;
	let totalBytes = 0;
	let cpuPercent = 0;
	let reclaimableTabCount = 0;
	let reclaimableBytes = 0;

	for (const process of snapshot?.processes ?? []) {
		const resident = process.metrics?.residentSizeBytes ?? 0;
		totalBytes += resident;
		cpuPercent += process.metrics?.cpuPercent ?? 0;
		if (process.kind !== "webContent" || process.tabs.length === 0) {
			system.push(process);
			systemBytes += resident;
			continue;
		}
		const perTab = resident / process.tabs.length;
		const unresponsive = process.webProcessIsResponsive === false;
		for (const tab of process.tabs) {
			tabs.push({ tab, process, bytes: perTab, shared: process.tabs.length > 1, unresponsive });
		}
		const sleepable = process.tabs.filter(isHiddenAndIdle).length;
		reclaimableTabCount += sleepable;
		// Memory only comes back when every tab of the process goes to sleep.
		if (sleepable === process.tabs.length) reclaimableBytes += resident;
	}

	tabs.sort((a, b) => Number(b.unresponsive) - Number(a.unresponsive) || b.bytes - a.bytes);
	system.sort((a, b) => (b.metrics?.residentSizeBytes ?? 0) - (a.metrics?.residentSizeBytes ?? 0));

	const byMemory = tabs.toSorted((a, b) => b.bytes - a.bytes);
	const segments: MemorySegment[] = byMemory
		.slice(0, NAMED_SEGMENTS)
		.map((usage) => ({ id: usage.tab.id, label: usage.tab.title, bytes: usage.bytes }));
	const othersBytes = byMemory.slice(NAMED_SEGMENTS).reduce((sum, usage) => sum + usage.bytes, 0);
	if (othersBytes > 0) segments.push({ id: "others", label: null, bytes: othersBytes });
	if (systemBytes > 0) segments.push({ id: "system", label: null, bytes: systemBytes });

	return {
		totalBytes,
		cpuPercent,
		tabs,
		system,
		systemBytes,
		segments,
		reclaimableTabCount,
		reclaimableBytes,
	};
}

export function filterTabUsages(tabs: TabUsage[], query: string): TabUsage[] {
	const normalized = query.trim().toLowerCase();
	if (!normalized) return tabs;
	return tabs.filter(
		({ tab }) =>
			tab.title.toLowerCase().includes(normalized) || tab.url.toLowerCase().includes(normalized),
	);
}
