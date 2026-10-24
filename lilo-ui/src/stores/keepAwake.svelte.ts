import { on } from "../lib/bridge";
import { keepAwakeActions } from "../lib/bridge/actions";
import type { BridgeKeepAwakeState, BridgeRunningApp, BridgeTerminalSummary } from "../lib/bridge/protocol";

const DEFAULT_NEVER_FREEZE = [
	"com.docker.docker", "com.electron.dockerdesktop", "dev.kdrag0n.MacVirt",
];

let _state = $state.raw<BridgeKeepAwakeState>({ keepsAwake: false, agents: [], tabIds: [], holdsLidClosed: false, helperStatus: "notRegistered" });
let _runningApps = $state.raw<BridgeRunningApp[]>([]);
let _terminals = $state.raw<BridgeTerminalSummary[]>([]);
let _appNames = $state.raw<Record<string, string>>({});

export function initKeepAwakeStore(): void {
	on("keepAwakeChanged", (data) => { _state = data; });
	on("runningApps", (data) => { _runningApps = data.apps; });
	on("terminalActivity", (data) => { _terminals = data.terminals; });
	on("appNames", (data) => { _appNames = { ..._appNames, ...data.names }; });
	keepAwakeActions.load();
}

export const getKeepAwakeState = (): BridgeKeepAwakeState => _state;
export const getRunningApps = (): BridgeRunningApp[] => _runningApps;
export const getTerminals = (): BridgeTerminalSummary[] => _terminals;
/** Display names of installed apps by bundle id, for the ones asked with `loadAppNames`. */
export const getAppNames = (): Record<string, string> => _appNames;

export function neverFreezeList(stored: string): string[] {
	if (!stored) return DEFAULT_NEVER_FREEZE;
	try {
		const parsed: unknown = JSON.parse(stored);
		return Array.isArray(parsed) ? parsed.filter((id): id is string => typeof id === "string") : DEFAULT_NEVER_FREEZE;
	} catch {
		return DEFAULT_NEVER_FREEZE;
	}
}

export const withApp = (list: string[], id: string): string[] => (list.includes(id) ? list : [...list, id]);
export const withoutApp = (list: string[], id: string): string[] => list.filter((entry) => entry !== id);
