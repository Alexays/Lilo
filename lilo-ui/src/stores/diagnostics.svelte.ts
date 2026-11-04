import { on } from "../lib/bridge";
import { settingsActions } from "../lib/bridge/actions";
import type {
	BridgeExtensionDiagnosticSnapshot,
	BridgeSettingsActionStatusPayload,
	BridgeStartupMetricMarkSnapshot,
	BridgeStartupMetricSummary,
	BridgeStartupTraceSnapshot,
	BridgeTabLifecycleDiagnostics,
} from "../lib/bridge/protocol";

// What the Diagnostics screen shows, shared by its navigation (the error count, the recording) and its page.
const DIAGNOSTIC_ACTIONS = new Set([
	"clearExtensionDiagnostics",
	"copyExtensionDiagnostics",
	"copyDiagnosticsReport",
	"forceLifecycleTrim",
	"togglePerfRecording",
]);

let _extensionDiagnostics = $state.raw<BridgeExtensionDiagnosticSnapshot[]>([]);
let _startupSummary = $state.raw<BridgeStartupMetricSummary | null>(null);
let _startupMarks = $state.raw<BridgeStartupMetricMarkSnapshot[]>([]);
let _startupTraces = $state.raw<BridgeStartupTraceSnapshot[]>([]);
let _lifecycle = $state.raw<BridgeTabLifecycleDiagnostics | null>(null);
let _status = $state<BridgeSettingsActionStatusPayload | null>(null);
let _recordingStartedAt = $state<number | null>(null);
let _listening = false;

export const getExtensionDiagnostics = (): BridgeExtensionDiagnosticSnapshot[] => _extensionDiagnostics;
export const getStartupSummary = (): BridgeStartupMetricSummary | null => _startupSummary;
export const getStartupMarks = (): BridgeStartupMetricMarkSnapshot[] => _startupMarks;
export const getStartupTraces = (): BridgeStartupTraceSnapshot[] => _startupTraces;
export const getLifecycleDiagnostics = (): BridgeTabLifecycleDiagnostics | null => _lifecycle;
export const getRecordingStartedAt = (): number | null => _recordingStartedAt;
export const getDiagnosticsStatus = (): BridgeSettingsActionStatusPayload | null => _status;

export function setDiagnosticsStatus(status: BridgeSettingsActionStatusPayload | null): void {
	_status = status;
}

/** Asks for fresh data; listens from the first open on. */
export function loadDiagnostics(): void {
	if (!_listening) {
		_listening = true;
		on("extensionDiagnosticsLoaded", (data) => {
			_extensionDiagnostics = data.entries ?? [];
		});
		on("startupMetricsLoaded", (data) => {
			_startupSummary = data.summary ?? null;
			_startupMarks = data.marks ?? [];
			_startupTraces = data.traces ?? [];
			_lifecycle = data.lifecycleDiagnostics ?? null;
			_recordingStartedAt = data.perfRecordingStartedAt ?? null;
		});
		on("perfRecordingChanged", (data) => {
			_recordingStartedAt = data.startedAt;
		});
		on("settingsActionCompleted", (data) => {
			if (DIAGNOSTIC_ACTIONS.has(data.action)) _status = data;
		});
	}
	settingsActions.loadStartupMetrics();
	settingsActions.loadExtensionDiagnostics();
}
