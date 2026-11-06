// How the open tab list is laid out: site stacks, project trays, and the agents and terminals trays.

/** A site's loose tabs stack from this many, and stay stacked until one is left. */
export const STACK_MIN = 3;

export type RowType = "agent" | "terminal" | "web";

export type ArrangeEntry = {
	id: string;
	type: RowType;
	/** The site a loose web tab can stack under, null for anything that never stacks. */
	host: string | null;
	/** The repository a terminal or a conversation works in, null for anything else. */
	project: string | null;
};

export type ArrangedRow = ArrangeEntry & {
	/** The stacked site this row belongs to. */
	stack: string | null;
	/** The tray this row sits in: `project:<root>` grouped by project, else its type grouped by type. */
	tray: string | null;
};

/** The sites stacked now: those with STACK_MIN loose tabs, and those already stacked still holding two. */
export function nextStackHosts(
	entries: readonly ArrangeEntry[],
	previous: ReadonlySet<string>,
	never: ReadonlySet<string>,
): Set<string> {
	const counts = new Map<string, number>();
	for (const entry of entries) {
		if (entry.host && !never.has(entry.host)) counts.set(entry.host, (counts.get(entry.host) ?? 0) + 1);
	}
	const hosts = new Set<string>();
	for (const [host, count] of counts) {
		if (count >= STACK_MIN || (count >= 2 && previous.has(host))) hosts.add(host);
	}
	return hosts;
}

/** The rows in display order: with `byProject`, a tray per project holding two rows or more, then
 *  with `grouped` agents, terminals and the rest; a stack's members follow one another from its
 *  topmost member's place. Each tray keeps the list's order. */
export function arrangeRows(
	entries: readonly ArrangeEntry[],
	stacked: ReadonlySet<string>,
	grouped: boolean,
	byProject: boolean,
): ArrangedRow[] {
	const counts = new Map<string, number>();
	if (byProject) for (const entry of entries) if (entry.project) counts.set(entry.project, (counts.get(entry.project) ?? 0) + 1);
	const buckets = new Map<string, ArrangeEntry[]>();
	const rest: ArrangeEntry[] = [];
	for (const entry of entries) {
		if (!entry.project || (counts.get(entry.project) ?? 0) < 2) {
			rest.push(entry);
			continue;
		}
		const key = `project:${entry.project}`;
		const bucket = buckets.get(key);
		if (bucket) bucket.push(entry);
		else buckets.set(key, [entry]);
	}
	const trays = grouped && new Set(rest.map((entry) => entry.type)).size > 1;
	for (const type of trays ? (["agent", "terminal", "web"] as const) : (["web"] as const)) {
		buckets.set(type, trays ? rest.filter((entry) => entry.type === type) : rest);
	}
	const rows: ArrangedRow[] = [];
	for (const [key, members] of buckets) {
		const tray = key === "web" ? null : key;
		const stacks = new Map<string, ArrangedRow[]>();
		for (const entry of members) {
			const stack = entry.host && stacked.has(entry.host) ? entry.host : null;
			const row = { ...entry, stack, tray };
			if (!stack) {
				rows.push(row);
				continue;
			}
			const group = stacks.get(stack);
			if (group) {
				group.push(row);
				continue;
			}
			// The stack's place is its first member's: later members join it there.
			const fresh = [row];
			stacks.set(stack, fresh);
			rows.push(...fresh);
		}
		// Splice each stack's members in after its first one.
		for (const [, group] of stacks) {
			// A site down to one tab, while the list holds still under the pointer, is a plain row again.
			if (group.length < 2) {
				group[0].stack = null;
				continue;
			}
			const at = rows.indexOf(group[0]);
			rows.splice(at + 1, 0, ...group.slice(1));
		}
	}
	return rows;
}

// Space-padded bars, dots and dashes, or a colon: what sites put between a page's title and their name.
const SEPARATOR = /(\s+[|·–—-]\s+|:\s+)/;

/** The stack's name: the part its pages' titles share at their start or end (a site name, a
 *  repository), else the host. */
export function stackName(titles: readonly string[], host: string): string {
	const counts = new Map<string, number>();
	for (const title of titles) {
		const parts = title.split(SEPARATOR);
		if (parts.length < 3) continue;
		const ends = new Set([parts[0].trim(), parts[parts.length - 1].trim()]);
		for (const end of ends) if (end) counts.set(end, (counts.get(end) ?? 0) + 1);
	}
	let name = host;
	let best = 1;
	for (const [end, count] of counts) {
		if (count > best) {
			name = end;
			best = count;
		}
	}
	return name;
}

/** A member's title without the stack's name, which its row already sits under. */
export function strippedTitle(title: string, name: string): string {
	const parts = title.split(SEPARATOR);
	if (parts.length < 3) return title;
	if (parts[parts.length - 1].trim() === name) return parts.slice(0, -2).join("").trim() || title;
	if (parts[0].trim() === name) return parts.slice(2).join("").trim() || title;
	return title;
}
