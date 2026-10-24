interface TerminalTitleSource {
  title?: string;
  terminalState?: string;
  terminalCommand?: string;
  cwd?: string;
}

/** Last folder of a working directory, "~" for the home folder. */
export function terminalFolder(cwd: string): string {
  if (!cwd) return "";
  if (/^\/Users\/[^/]+\/?$/.test(cwd)) return "~";
  const trimmed = cwd.replace(/\/+$/, "");
  return trimmed.slice(trimmed.lastIndexOf("/") + 1) || "/";
}

/** A duration in seconds as "42s", "3m 12s" or "2h 13m". */
export function formatTerminalDuration(seconds: number): string {
  const total = Math.max(0, Math.round(seconds));
  if (total < 60) return `${total}s`;
  if (total < 3600) return `${Math.floor(total / 60)}m ${total % 60}s`;
  return `${Math.floor(total / 3600)}h ${Math.floor((total % 3600) / 60)}m`;
}

/**
 * What a terminal row shows: while a command runs, the title it set (an agent's topic) or the
 * command itself; at the prompt, the folder it sits in.
 */
export function terminalTitle(tab: TerminalTitleSource): string {
  const folder = terminalFolder(tab.cwd ?? "");
  if (tab.terminalState !== "busy" && tab.terminalState !== "waiting") return folder;
  return tab.title?.trim() || tab.terminalCommand?.trim() || folder;
}
