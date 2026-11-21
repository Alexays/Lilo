// The `agentAcpInstances` setting: the agents the user manages in Settings > Agents. A registry agent
// with no entry is enabled; a disabled entry is only filtered out of the pickers, so the
// conversations started with it keep working. Swift reads the same JSON to resolve command agents.
export interface AgentInstance {
  /** A registry entry's registry id; a command entry gets a unique one when added. */
  id: string;
  source: "registry" | "command";
  /** The registry agent id (equal to `id` while an agent has at most one instance). */
  registryId?: string;
  /** The command's label, or the registry name read when it was added. */
  name?: string;
  /** A command's full executable path, one-argument-per-line arguments and `NAME=value` lines. */
  executable?: string;
  arguments?: string;
  environment?: string;
  enabled: boolean;
}

/** The fields the custom-command form edits. */
export interface CommandFields {
  name: string;
  executable: string;
  arguments: string;
  environment: string;
}

export function parseAgentInstances(stored: string): AgentInstance[] {
  try {
    const parsed: unknown = JSON.parse(stored || "[]");
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((entry): entry is AgentInstance => {
      const instance = entry as Partial<AgentInstance> | null;
      return (
        typeof instance?.id === "string" &&
        instance.id.length > 0 &&
        (instance.source === "registry" || instance.source === "command") &&
        (instance.enabled === undefined || typeof instance.enabled === "boolean")
      );
    }).map((entry) => ({ ...entry, enabled: entry.enabled !== false }));
  } catch {
    return [];
  }
}

/** The ids the pickers hide: the registry id of a registry entry, the entry's own id otherwise. */
export function disabledAgentIds(instances: AgentInstance[]): Set<string> {
  return new Set(instances.filter((entry) => !entry.enabled).map((entry) => entry.registryId ?? entry.id));
}

export function writeAgentInstances(instances: AgentInstance[]): string {
  return JSON.stringify(
    instances.map((entry) => {
      const stored: Record<string, unknown> = { id: entry.id, source: entry.source, enabled: entry.enabled };
      if (entry.registryId) stored.registryId = entry.registryId;
      if (entry.name) stored.name = entry.name;
      if (entry.executable) stored.executable = entry.executable;
      if (entry.arguments) stored.arguments = entry.arguments;
      if (entry.environment) stored.environment = entry.environment;
      return stored;
    }),
  );
}

export function newCommandId(): string {
  return `command-${crypto.randomUUID()}`;
}
