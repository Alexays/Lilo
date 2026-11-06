// How the open tab list is laid out: site stacks, the agents and terminals trays, and its scroll window.

/** A site's loose tabs stack from this many, and stay stacked until one is left. */
export const STACK_MIN = 3;

export type RowType = "agent" | "terminal" | "web";

export type ArrangeEntry = {
	id: string;
	type: RowType;
	/** The site a loose web tab can stack under, null for anything that never stacks. */
	host: string | null;
};

export type ArrangedRow = ArrangeEntry & {
	/** The stacked site this row belongs to. */
	stack: string | null;
	/** The tray this row sits in, when the list is grouped by type. */
	tray: Exclude<RowType, "web"> | null;
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

/** The rows in display order: with `grouped`, agents then terminals then the rest; a stack's
 *  members follow one another from its topmost member's place. Each kind keeps the list's order. */
export function arrangeRows(
	entries: readonly ArrangeEntry[],
	stacked: ReadonlySet<string>,
	grouped: boolean,
): ArrangedRow[] {
	const trays = grouped && new Set(entries.map((entry) => entry.type)).size > 1;
	const order: RowType[] = trays ? ["agent", "terminal", "web"] : ["web"];
	const rows: ArrangedRow[] = [];
	for (const type of order) {
		const members = new Map<string, ArrangedRow[]>();
		const inType = trays ? entries.filter((entry) => entry.type === type) : entries;
		for (const entry of inType) {
			const stack = entry.host && stacked.has(entry.host) ? entry.host : null;
			const row = { ...entry, stack, tray: trays && type !== "web" ? type : null };
			if (!stack) {
				rows.push(row);
				continue;
			}
			const group = members.get(stack);
			if (group) {
				group.push(row);
				continue;
			}
			// The stack's place is its first member's: later members join it there.
			const fresh = [row];
			members.set(stack, fresh);
			rows.push(...fresh);
		}
		// Splice each stack's members in after its first one.
		for (const [, group] of members) {
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

/** The gap between two rows, mirroring --sidebar-tab-row-gap. */
export const VIRTUAL_ROW_GAP = 2;

export type WindowRow<T> = { kind: "item"; item: T; top: number } | { kind: "spacer"; key: string; height: number };

/** Rows stacked down from `top`: those outside [minY, maxY] and not kept fold into spacers. */
export function windowRows<T>(
	items: readonly T[],
	top: number,
	minY: number,
	maxY: number,
	heightOf: (item: T) => number,
	keep: (item: T) => boolean,
): WindowRow<T>[] {
	const rows: WindowRow<T>[] = [];
	let hiddenHeight = 0;
	let hiddenCount = 0;
	let spacers = 0;
	const flush = () => {
		if (hiddenCount === 0) return;
		// The list's gap supplies the gaps around a spacer: it only carries the hidden rows and the gaps between them.
		rows.push({ kind: "spacer", key: `spacer-${spacers++}`, height: hiddenHeight + (hiddenCount - 1) * VIRTUAL_ROW_GAP });
		hiddenHeight = 0;
		hiddenCount = 0;
	};
	for (const item of items) {
		const height = heightOf(item);
		if ((top + height >= minY && top <= maxY) || keep(item)) {
			flush();
			rows.push({ kind: "item", item, top });
		} else {
			hiddenHeight += height;
			hiddenCount += 1;
		}
		top += height + VIRTUAL_ROW_GAP;
	}
	flush();
	return rows;
}
