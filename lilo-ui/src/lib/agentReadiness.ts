import type { BridgeAgentAuthMethod, BridgeAgentChoice, BridgeAgentInfo } from "./bridge/protocol";

/** How a picker or a Settings row presents an agent: `unknown` is an agent nobody probed yet. */
export type AgentStatus = "ready" | "needsSignIn" | "unavailable" | "unverified" | "unknown";

export function agentStatus(agent: Pick<BridgeAgentInfo, "readiness">): AgentStatus {
	return agent.readiness?.state ?? "unknown";
}

/**
 * Only an agent that cannot start is out of the picker's reach. One that needs a sign-in is still picked:
 * the conversation signs in, in its thread, as the agent asks. One never probed, or whose probe failed, is
 * picked as before.
 */
export function isPickable(agent: Pick<BridgeAgentInfo, "readiness">): boolean {
	return agentStatus(agent) !== "unavailable";
}

/** Why an agent is not simply ready, for next to its name: the agent's own reason, else the status's name. */
export function agentNote(
	agent: Pick<BridgeAgentInfo, "readiness">,
	labels: Record<"needsSignIn" | "unavailable" | "unverified", string>,
): string | undefined {
	const status = agentStatus(agent);
	if (status === "ready" || status === "unknown") return undefined;
	const reason = agent.readiness?.reason?.trim();
	// Signing in needs no reason: the status says it.
	if (status === "needsSignIn") return labels.needsSignIn;
	return reason || labels[status];
}

/** The methods the agent declared that Lilo can run; one that is neither `agent` nor `terminal` is left out. */
export function signInMethods(agent: Pick<BridgeAgentInfo, "readiness">): BridgeAgentAuthMethod[] {
	return (agent.readiness?.authMethods ?? []).filter((method) => method.type === "agent" || method.type === "terminal");
}

/** What the model control of a conversation shows. `null`: nothing to add, the session's own picker is there. */
export type ModelControl =
	| { kind: "list"; configId: string; current: string; options: BridgeAgentChoice[] }
	| { kind: "custom" }
	| null;

/**
 * The agent's models from its record while its session has none to offer (before the first prompt), else
 * a field to type a model id into once the agent is known to expose no models at all: its record says so,
 * or its session opened with options and none of them is a model.
 */
export function modelControl(agent: BridgeAgentInfo | undefined, session: { hasModels: boolean; opened: boolean }): ModelControl {
	if (session.hasModels || !agent || agentStatus(agent) === "unavailable") return null;
	const readiness = agent.readiness;
	const models = readiness?.models ?? [];
	if (readiness?.modelConfigId && models.length > 0) {
		return { kind: "list", configId: readiness.modelConfigId, current: readiness.currentModel ?? "", options: models };
	}
	// A record listing models without an option to set them (ACP's earlier shape) leaves nothing to pick from.
	if (models.length > 0) return null;
	return readiness?.state === "ready" || session.opened ? { kind: "custom" } : null;
}

/** The id as typed, or null when there is nothing to send. */
export function parseModelId(text: string): string | null {
	const id = text.trim();
	return id.length > 0 && !/\s/.test(id) ? id : null;
}
