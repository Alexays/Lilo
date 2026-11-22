import { on } from "../lib/bridge";
import { settingsActions } from "../lib/bridge/actions";
import type { BridgeAgentActionLog } from "../lib/bridge/protocol";

let _log = $state.raw<BridgeAgentActionLog["clients"] | null>(null);

// Registered on import: only the Settings activity list imports this, so it stays out of the first frame.
on("agentActionLog", (data) => {
	_log = data.clients ?? [];
});

/** Each agent's latest calls; null until native has read the log once. */
export function getAgentActionLog(): BridgeAgentActionLog["clients"] | null {
	return _log;
}

/** Native reads the tail of each log when asked, never on its own: the page asks as it opens and on Refresh. */
export function loadAgentActionLog(): void {
	settingsActions.loadAgentActionLog();
}

export function openAgentActionLog(): void {
	settingsActions.openAgentActionLog();
}
