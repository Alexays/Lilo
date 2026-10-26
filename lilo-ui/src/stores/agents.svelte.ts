import { on } from "../lib/bridge";
import { agentActions, settingsActions } from "../lib/bridge/actions";
import type { BridgeAgentClient } from "../lib/bridge/protocol";
import { getAgentClientsSnapshot } from "./settings.svelte";

let _clients = $state.raw<BridgeAgentClient[]>([]);
let _agentsSpaceIds = $state.raw<string[]>([]);
let _agentsProfileId = $state("");
let _hiddenAgentsSpaceIds = $state.raw<string[]>([]);
// Names whose app icon was asked for once, so a name with no known app does not reload on every event.
const _iconRequested = new Set<string>();

export function initAgentsStore(): void {
	on("agentActivity", (data) => {
		_clients = data.clients;
		_agentsSpaceIds = data.agentsSpaceIds;
		_agentsProfileId = data.agentsProfileId ?? "";
		_hiddenAgentsSpaceIds = data.hiddenAgentsSpaceIds;
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

const _icons = $derived.by(() => {
	const { clients, allowed } = getAgentClientsSnapshot();
	const icons: Record<string, string[]> = {};
	// Acting agents last, so they draw in front.
	for (const client of [..._clients].sort((a, b) => Number(a.busy) - Number(b.busy))) {
		const id = allowed.find((agent) => agent.name === client.name)?.client;
		const icon = id && clients.find((entry) => entry.id === id)?.icon;
		if (!icon) continue;
		for (const spaceId of client.spaceIds) {
			const list = (icons[spaceId] ??= []);
			const seen = list.indexOf(icon);
			if (seen >= 0) list.splice(seen, 1);
			list.push(icon);
		}
	}
	return icons;
});

/** App icons of the agents Lilo knows working in the space, the acting ones last; none when none is known. */
export const getAgentIcons = (spaceId: string): string[] | undefined => _icons[spaceId];
