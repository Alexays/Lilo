import { on } from "../lib/bridge";
import { agentActions, settingsActions } from "../lib/bridge/actions";
import type { BridgeAgentClient } from "../lib/bridge/protocol";
import { getAgentClientsSnapshot } from "./settings.svelte";

let _clients = $state.raw<BridgeAgentClient[]>([]);
let _agentsSpaceId = $state("");
let _agentsProfileId = $state("");
let _agentsSpaceVisible = $state(false);
// Names whose app icon was asked for once, so a name with no known app does not reload on every event.
const _iconRequested = new Set<string>();

export function initAgentsStore(): void {
	on("agentActivity", (data) => {
		_clients = data.clients;
		_agentsSpaceId = data.agentsSpaceId;
		_agentsProfileId = data.agentsProfileId ?? "";
		_agentsSpaceVisible = data.agentsSpaceVisible;
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

/** The space agents work in, empty before the first one connects. */
export const getAgentsSpaceId = (): string => _agentsSpaceId;

/** The agents' throwaway profile, empty before the first agent: never one of the user's profiles. */
export const getAgentsProfileId = (): string => _agentsProfileId;

/** False while no agent is connected and the Agents space holds no tab. */
export const isAgentsSpaceVisible = (): boolean => _agentsSpaceVisible;

export const isAnyAgentActing = (): boolean => _clients.some((client) => client.busy);

const _icons = $derived.by(() => {
	const { clients, allowed } = getAgentClientsSnapshot();
	const icons: string[] = [];
	// Acting agents last, so they draw in front.
	for (const client of [..._clients].sort((a, b) => Number(a.busy) - Number(b.busy))) {
		const id = allowed.find((agent) => agent.name === client.name)?.client;
		const icon = id && clients.find((entry) => entry.id === id)?.icon;
		if (!icon) continue;
		const seen = icons.indexOf(icon);
		if (seen >= 0) icons.splice(seen, 1);
		icons.push(icon);
	}
	return icons;
});

/** App icons of the connected agents Lilo knows, the acting ones last; empty when none is known. */
export const getAgentIcons = (): string[] => _icons;
