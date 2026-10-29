import { on } from "../lib/bridge";
import { agentActions, settingsActions } from "../lib/bridge/actions";
import type { BridgeAgentClient, BridgeAgentMood } from "../lib/bridge/protocol";
import { getAgentClientsSnapshot } from "./settings.svelte";

let _clients = $state.raw<BridgeAgentClient[]>([]);
let _agentsSpaceIds = $state.raw<string[]>([]);
let _agentsProfileId = $state("");
let _hiddenAgentsSpaceIds = $state.raw<string[]>([]);
let _moods = $state.raw<Record<string, BridgeAgentMood>>({});
// Names whose app icon was asked for once, so a name with no known app does not reload on every event.
const _iconRequested = new Set<string>();

export function initAgentsStore(): void {
	on("agentActivity", (data) => {
		_clients = data.clients;
		_agentsSpaceIds = data.agentsSpaceIds;
		_agentsProfileId = data.agentsProfileId ?? "";
		_hiddenAgentsSpaceIds = data.hiddenAgentsSpaceIds;
		// Between two calls a space keeps its mood while its agents still act, like the cursor.
		const moods = data.moods;
		for (const [spaceId, mood] of Object.entries(_moods)) {
			if (!moods[spaceId] && data.clients.some((client) => client.actingTabIds.length && client.spaceIds.includes(spaceId)))
				moods[spaceId] = mood;
		}
		_moods = moods;
		const allowed = getAgentClientsSnapshot().allowed;
		const fresh = data.clients.filter(
			(client) => !_iconRequested.has(client.name) && !allowed.some((agent) => agent.name === client.name),
		);
		for (const client of fresh) _iconRequested.add(client.name);
		if (fresh.length) settingsActions.loadAgentClients();
	});
	agentActions.load();
}

/** Agents connected to Lilo, and whether each is acting now. */
export const getAgentClients = (): BridgeAgentClient[] => _clients;

const _actingTabIds = $derived(new Set(_clients.flatMap((client) => client.actingTabIds)));

/** Tabs an agent acts on now, or did a moment ago. */
export const getActingAgentTabIds = (): Set<string> => _actingTabIds;

/** The spaces agents work in, one per profile, empty before the first one connects. */
export const getAgentsSpaceIds = (): string[] => _agentsSpaceIds;

export const isAgentsSpace = (spaceId: string): boolean => _agentsSpaceIds.includes(spaceId);

/** The agents' throwaway profile, empty before the first agent: never one of the user's profiles. */
export const getAgentsProfileId = (): string => _agentsProfileId;

/** An Agents space no agent works in and holding no tab. */
export const isHiddenAgentsSpace = (spaceId: string): boolean => _hiddenAgentsSpaceIds.includes(spaceId);

/** What the agents in the space act out now, none while they are idle. */
export const getAgentMood = (spaceId: string): BridgeAgentMood | undefined => _moods[spaceId];
