/** What one agent may do on pages without asking, as Swift's `AgentClientPermission` stores it, by client name. */
export interface AgentClientPermission {
  act: "ask" | "always";
  sites: string[];
}

export const DEFAULT_AGENT_PERMISSION: AgentClientPermission = { act: "ask", sites: [] };

export function parseAgentPermissions(stored: string): Record<string, AgentClientPermission> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stored || "{}");
  } catch {
    return {};
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
  const result: Record<string, AgentClientPermission> = {};
  for (const [name, entry] of Object.entries(parsed)) {
    const value = (entry ?? {}) as { act?: unknown; sites?: unknown };
    result[name] = {
      act: value.act === "always" ? "always" : "ask",
      sites: Array.isArray(value.sites) ? value.sites.filter((site): site is string => typeof site === "string") : [],
    };
  }
  return result;
}

/** The stored value with `name` set to `permission`; a client back at the default is dropped, as Swift does. */
export function setAgentPermission(stored: string, name: string, permission: AgentClientPermission): string {
  const all = parseAgentPermissions(stored);
  all[name] = permission;
  return JSON.stringify(Object.fromEntries(Object.entries(all).filter(([, entry]) => entry.act !== "ask" || entry.sites.length > 0)));
}

/** The host a user typed or pasted: "https://Shop.Example.com/cart" gives "shop.example.com"; "" when it names none. */
export function normalizeSite(input: string): string {
  const text = input.trim().toLowerCase();
  if (!text) return "";
  try {
    const host = new URL(text.includes("://") ? text : `https://${text}`).hostname.replace(/\.$/, "");
    return /^[a-z0-9.-]+$/.test(host) && host.includes(".") || host === "localhost" ? host : "";
  } catch {
    return "";
  }
}
