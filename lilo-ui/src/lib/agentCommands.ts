// The agents settings: `agentCommands` lists the user's own commands, which Swift reads to start them, and
// `agentsHidden` the ids of the catalog agents the pickers leave out. A hidden agent keeps running where a
// conversation already uses it.
export interface AgentCommand {
  /** `command-` and a UUID, given when added. */
  id: string;
  name: string;
  /** The full path of an executable, then one argument and one `NAME=value` line per line. */
  executable: string;
  arguments: string;
  environment: string;
}

/** The stored commands; an entry without an id is dropped, a missing field reads as empty. */
export function parseAgentCommands(stored: string): AgentCommand[] {
  try {
    const parsed: unknown = JSON.parse(stored || "[]");
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((entry): entry is Partial<AgentCommand> => typeof entry?.id === "string" && entry.id.length > 0)
      .map((entry) => ({
        id: entry.id!,
        name: String(entry.name ?? ""),
        executable: String(entry.executable ?? ""),
        arguments: String(entry.arguments ?? ""),
        environment: String(entry.environment ?? ""),
      }));
  } catch {
    return [];
  }
}

export function parseHiddenAgents(stored: string): Set<string> {
  try {
    const parsed: unknown = JSON.parse(stored || "[]");
    return new Set(Array.isArray(parsed) ? parsed.filter((id): id is string => typeof id === "string") : []);
  } catch {
    return new Set();
  }
}
