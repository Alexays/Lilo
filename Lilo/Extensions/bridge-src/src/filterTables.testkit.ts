// The filter tables as WKEngineFactory hands them to GenericCosmetics.js and FilterLookup.js, for their tests and
// those of the page scripts FilterLookup.js serves.
import { readFileSync } from "node:fs";

const lookupSource = readFileSync(new URL("../../../ContentBlocker/FilterLookup.js", import.meta.url), "utf8");

const DIGITS = "+/0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

function fnv(key: string, seed: number): number {
	let hash = seed;
	for (let i = 0; i < key.length; i++) hash = Math.imul(hash ^ key.charCodeAt(i), 16777619) >>> 0;
	return hash;
}

/** WKEngineFactory.keyHash: 48 bits of two FNV-1a passes, in 8 sortable base-64 digits. */
export function keyHash(key: string): string {
	let value = fnv(key, 2166136261) * 65536 + (fnv(key, 0x9747b28c) >>> 16);
	let out = "";
	for (let d = 0; d < 8; d++) {
		out = DIGITS[value % 64] + out;
		value = Math.floor(value / 64);
	}
	return out;
}

/** WKEngineFactory.hostTable, without the Latin-1 spelling: entries are spliced as given. */
export function keyedTable(table: Record<string, string[]>): { index: string; groups: string; entries: string } {
	let groups = "";
	let entries = "";
	const refs = new Map<string, string>();
	const records: [string, number][] = [];
	for (const [key, list] of Object.entries(table)) {
		const keyRefs = list.map((entry) => {
			let ref = refs.get(entry);
			if (ref === undefined) {
				ref = entries.length.toString(36);
				refs.set(entry, ref);
				entries += entry + "\xa7";
			}
			return ref;
		});
		records.push([keyHash(key), groups.length]);
		groups += keyRefs.join(",") + "|";
	}
	records.sort((a, b) => (a[0] < b[0] ? -1 : 1));
	const index = records.map(([hash, group]) => hash + [18, 12, 6, 0].map((shift) => DIGITS[(group >> shift) & 63]).join("")).join("");
	return { index, groups, entries };
}

/**
 * FilterLookup.js over `table` for a frame at `location`: the window's event functions, which the table's page script
 * shares with it, and `lookup` to run it, before or after that script.
 */
export function lookupFrame(table: Record<string, string[]>, names: string[], allowlist: string[], location: unknown) {
	const { index, groups, entries } = keyedTable(table);
	const src = lookupSource
		.replace("__LILO_LOOKUP_INDEX__", JSON.stringify(index))
		.replace("__LILO_LOOKUP_GROUPS__", JSON.stringify(groups))
		.replace("__LILO_LOOKUP_TABLE__", JSON.stringify(entries))
		.replace("__LILO_LOOKUP_NAMES__", JSON.stringify(names.join(" ")))
		.replace("__LILO_ALLOWLIST__", JSON.stringify(`|${allowlist.join("|")}|`));
	const window = new EventTarget();
	const addEventListener = window.addEventListener.bind(window);
	const dispatchEvent = window.dispatchEvent.bind(window);
	const lookup = () => new Function("location", "addEventListener", "dispatchEvent", src)(location, addEventListener, dispatchEvent);
	return { addEventListener, dispatchEvent, lookup };
}

/** FNV-1a, the hash WKEngineFactory.tokenBuckets buckets tokens by. */
export function fnv1a(token: string): number {
	return fnv(token, 2166136261);
}

/** WKEngineFactory.tokenBuckets for a few tokens: 16 buckets. */
export function tokenBuckets(tokens: string[]): string {
	if (!tokens.length) return "";
	const buckets: string[][] = Array.from({ length: 16 }, () => []);
	for (const token of tokens) buckets[fnv1a(token) % 16].push(token);
	return buckets.map((b) => (b.length ? `|${b.join("|")}|` : "")).join(",");
}
