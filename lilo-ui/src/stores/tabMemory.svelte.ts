// WebKit reports memory per WebContent process, which several tabs can share, so a process's size is split evenly
// across its tabs. One shared timer ticks only while a tab is hovered and the window is visible.

import { on } from "../lib/bridge";
import { processManagerActions } from "../lib/bridge/actions";
import { formatByteSize } from "../lib/format";
import { getLocale, t } from "../lib/i18n/state.svelte";
import { onSidebarApplied } from "./sidebar.svelte";

// Raw: each update swaps the whole record, so deep proxying would only add overhead.
let tabMemoryBytes = $state.raw<Record<string, number>>({});
let tabCPUPercent = $state.raw<Record<string, number>>({});

export function initTabMemoryStore(): void {
	on("processSnapshotUpdated", (snapshot) => {
		const next: Record<string, number> = {};
		for (const process of snapshot.processes) {
			const resident = process.metrics?.residentSizeBytes;
			const tabs = process.tabs;
			if (!resident || resident <= 0 || tabs.length === 0) continue;
			const perTab = resident / tabs.length;
			for (const tab of tabs) {
				next[tab.id] = (next[tab.id] ?? 0) + perTab;
			}
		}
		tabMemoryBytes = next;
	});

	on("tabMemoryUpdated", ({ tabId, bytes, cpuPercent }) => {
		tabMemoryBytes = { ...tabMemoryBytes, [tabId]: bytes };
		if (cpuPercent !== undefined) tabCPUPercent = { ...tabCPUPercent, [tabId]: cpuPercent };
	});

	onSidebarApplied(({ closedTabIds }) => {
		const closed = closedTabIds.filter((id) => id in tabMemoryBytes || id in tabCPUPercent);
		if (closed.length === 0) return;
		const bytes = { ...tabMemoryBytes };
		const cpu = { ...tabCPUPercent };
		for (const id of closed) {
			delete bytes[id];
			delete cpu[id];
		}
		tabMemoryBytes = bytes;
		tabCPUPercent = cpu;
	});
}

/** A tab's memory ("120 MB") and CPU percent ("3", "<1"); null while nothing is known. */
export function tabUsage(tabId: string): { memory: string; cpu?: string } | null {
	const bytes = tabMemoryBytes[tabId];
	if (!bytes || bytes <= 0) return null;
	const cpu = tabCPUPercent[tabId];
	return { memory: formatByteSize(bytes, getLocale()), cpu: cpu === undefined ? undefined : cpu < 1 ? "<1" : String(Math.round(cpu)) };
}

/** "Memory ≈ 120 MB · CPU 3 %" for a tab's hover popup; empty while nothing is known. */
export function tabUsageLabel(tabId: string): string {
	const usage = tabUsage(tabId);
	if (!usage) return "";
	if (usage.cpu === undefined) return t("tabItem.memory", { value: usage.memory });
	return t("tabItem.usage", { memory: usage.memory, cpu: usage.cpu });
}

const LIVE_REFRESH_INTERVAL_MS = 2000;
const LIVE_REFRESH_CAP_MS = 8000;
let liveSubscribers = 0;
let liveTimer: ReturnType<typeof setTimeout> | null = null;
let liveIntervalMs = LIVE_REFRESH_INTERVAL_MS;
let lastLoadAt = -Infinity;
let liveTabId = "";

function tick(): void {
	// Skip the bridge round-trip when nothing is visible (window/app in background).
	if (typeof document === "undefined" || document.visibilityState === "visible") {
		lastLoadAt = Date.now();
		processManagerActions.loadTabMemory(liveTabId);
	}
	// A held hover backs off from 2 s to 8 s between snapshots; a fresh hover starts over.
	liveTimer = setTimeout(tick, liveIntervalMs);
	liveIntervalMs = Math.min(liveIntervalMs * 2, LIVE_REFRESH_CAP_MS);
}

/**
 * Start live-refreshing tab memory while a tab is hovered. Ref-counted across tabs so a
 * single shared timer covers them all; pair every call with stopTabMemoryLiveRefresh().
 */
export function startTabMemoryLiveRefresh(tabId: string): void {
	liveSubscribers++;
	liveTabId = tabId;
	if (liveTimer !== null) return;
	liveIntervalMs = LIVE_REFRESH_INTERVAL_MS;
	// Leading-edge throttle: sweeping the cursor across rows flips the refcount 0-to-1
	// repeatedly, and an unconditional first tick would burst memory requests.
	const sinceLastLoad = Date.now() - lastLoadAt;
	if (sinceLastLoad >= LIVE_REFRESH_INTERVAL_MS) {
		tick();
		return;
	}
	liveTimer = setTimeout(tick, LIVE_REFRESH_INTERVAL_MS - sinceLastLoad);
}

/** Release one live-refresh subscription; stops the shared timer once none remain. */
export function stopTabMemoryLiveRefresh(): void {
	liveSubscribers = Math.max(0, liveSubscribers - 1);
	if (liveSubscribers > 0 || liveTimer === null) return;
	clearTimeout(liveTimer);
	liveTimer = null;
}
