import type {
	BridgeExtensionDiagnosticSnapshot,
	BridgeStartupMetricMarkSnapshot,
	BridgeStartupTraceSnapshot,
} from "../../lib/bridge/protocol";

interface WaterfallRow {
	id: string;
	event: string;
	totalMs: number;
	deltaMs: number;
	/** Bar position and width as percentages of the whole boot. */
	startPct: number;
	widthPct: number;
	slowest: boolean;
}

export type LogFilter = "all" | "errors" | "extensions" | "traces";

interface LogEntry {
	id: string;
	kind: "extension" | "trace";
	level: "info" | "warning" | "error";
	timestamp: number;
	/** Extension name for extension entries, category for traces. */
	title: string;
	message: string;
	detail: string | null;
	durationMs: number | null;
}

export function formatEventName(value: string): string {
	return value
		.replace(/([a-z0-9])([A-Z])/g, "$1 $2")
		.replace(/([A-Z])([A-Z][a-z])/g, "$1 $2")
		.replace(/_/g, " ")
		.replace(/^./, (char) => char.toUpperCase());
}

export function startupWaterfall(marks: BridgeStartupMetricMarkSnapshot[]): WaterfallRow[] {
	let endMs = 0;
	let slowestDelta = 0;
	for (const mark of marks) {
		endMs = Math.max(endMs, mark.totalMilliseconds);
		slowestDelta = Math.max(slowestDelta, mark.deltaMilliseconds);
	}
	if (endMs <= 0) return [];
	return marks.map((mark) => {
		const startMs = Math.max(0, mark.totalMilliseconds - mark.deltaMilliseconds);
		return {
			id: mark.id,
			event: mark.event,
			totalMs: mark.totalMilliseconds,
			deltaMs: mark.deltaMilliseconds,
			startPct: (startMs / endMs) * 100,
			widthPct: (mark.deltaMilliseconds / endMs) * 100,
			slowest: slowestDelta > 0 && mark.deltaMilliseconds === slowestDelta,
		};
	});
}

/** Extension diagnostics and runtime traces in one stream, newest first. */
export function logEntries(
	extensionEntries: BridgeExtensionDiagnosticSnapshot[],
	traces: BridgeStartupTraceSnapshot[],
	extensionLabel: (extensionId: string) => string,
): LogEntry[] {
	const entries: LogEntry[] = [];
	for (const entry of extensionEntries) {
		const details = Object.entries(entry.metadata ?? {})
			.filter(([, value]) => value.length > 0)
			.map(([key, value]) => `${key}: ${value}`);
		entries.push({
			id: `ext-${entry.id}`,
			kind: "extension",
			level: entry.level,
			timestamp: entry.timestamp,
			title: extensionLabel(entry.extensionId),
			message: entry.source ? `[${entry.source}] ${entry.message}` : entry.message,
			detail: details.length > 0 ? details.join(", ") : null,
			durationMs: null,
		});
	}
	for (const trace of traces) {
		entries.push({
			id: `trace-${trace.id}`,
			kind: "trace",
			level: "info",
			timestamp: trace.timestamp,
			title: trace.category,
			message: trace.message,
			detail: null,
			durationMs: trace.totalMilliseconds,
		});
	}
	return entries.sort((a, b) => b.timestamp - a.timestamp);
}

export function filterLog(entries: LogEntry[], filter: LogFilter, query: string): LogEntry[] {
	const normalized = query.trim().toLowerCase();
	return entries.filter((entry) => {
		if (filter === "errors" && entry.level !== "error") return false;
		if (filter === "extensions" && entry.kind !== "extension") return false;
		if (filter === "traces" && entry.kind !== "trace") return false;
		if (!normalized) return true;
		return (
			entry.message.toLowerCase().includes(normalized) ||
			entry.title.toLowerCase().includes(normalized) ||
			(entry.detail?.toLowerCase().includes(normalized) ?? false)
		);
	});
}
