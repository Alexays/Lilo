import type { Locale } from "../../lib/i18n/translate";

export type ReleaseKind = "Breaking" | "Added" | "Changed" | "Fixed";
const illustrations = ["unread", "calls", "share", "address", "history", "pip", "languages", "fresh", "archive", "material", "colors"] as const;
export type ReleaseIllustration = typeof illustrations[number];

export interface ReleaseHighlight {
	illustration: ReleaseIllustration;
	titleKey: string;
	descriptionKey: string;
}

export interface ReleaseEditorial {
	headlineKey: string;
	descriptionKey: string;
	highlights: ReleaseHighlight[];
}

export interface ReleaseEditorialCopy {
	headline: string;
	description: string;
	highlights: { illustration: ReleaseIllustration; title: string; description: string }[];
}

export interface ReleaseNotes {
	version: string;
	date: string;
	groups: { kind: ReleaseKind; entries: string[] }[];
	editorial?: Partial<Record<Locale, ReleaseEditorialCopy | null>> | null;
}

export function parseReleaseNotes(markdown: string, version: string): ReleaseNotes {
	const release: ReleaseNotes = { version, date: "", groups: [] };
	let active = false;
	let group: ReleaseNotes["groups"][number] | undefined;
	for (const line of markdown.split(/\r?\n/)) {
		const header = /^## \[([^\]]+)\](?: - (\d{4}-\d{2}-\d{2}))?/.exec(line);
		if (header) {
			if (active) break;
			active = header[1] === version;
			if (active && header[2]) {
				const date = new Date(`${header[2]}T00:00:00Z`);
				if (Number.isFinite(date.getTime()) && date.toISOString().startsWith(header[2])) release.date = header[2];
			}
			continue;
		}
		if (!active) continue;
		if (line.startsWith("### ")) {
			const kind = line.slice(4).trim();
			group = ["Breaking", "Added", "Changed", "Fixed"].includes(kind)
				? { kind: kind as ReleaseKind, entries: [] } : undefined;
			if (group) release.groups.push(group);
		} else if (group) {
			const entry = /^-\s+(\S.*)$/.exec(line);
			if (entry) group.entries.push(entry[1]);
			else if (/^\s+\S/.test(line) && group.entries.length) group.entries[group.entries.length - 1] += `\n${line.trim()}`;
		}
	}
	release.groups = release.groups.filter((item) => item.entries.length > 0);
	return release;
}

function record(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

function key(value: unknown): value is string {
	return typeof value === "string" && value.trim().length > 0;
}

export function releaseHighlightsForVersion(registry: unknown, version: string): ReleaseEditorial | null {
	if (!record(registry) || !Object.hasOwn(registry, version)) return null;
	const entry = registry[version];
	if (!record(entry) || !key(entry.headlineKey) || !key(entry.descriptionKey) || !Array.isArray(entry.highlights)) return null;
	const highlights: ReleaseHighlight[] = [];
	for (const value of entry.highlights) {
		if (!record(value) || !illustrations.includes(value.illustration as ReleaseIllustration)
			|| !key(value.titleKey) || !key(value.descriptionKey)) continue;
		highlights.push({ illustration: value.illustration as ReleaseIllustration, titleKey: value.titleKey.trim(), descriptionKey: value.descriptionKey.trim() });
		if (highlights.length === 3) break;
	}
	return highlights.length ? { headlineKey: entry.headlineKey.trim(), descriptionKey: entry.descriptionKey.trim(), highlights } : null;
}

export function localizeReleaseEditorial(editorial: ReleaseEditorial | null, catalog: unknown): ReleaseEditorialCopy | null {
	if (!editorial) return null;
	const text = (path: string): string => {
		const value = path.split(".").reduce<unknown>((node, segment) => record(node) ? node[segment] : undefined, catalog);
		return typeof value === "string" ? value : "";
	};
	const headline = text(editorial.headlineKey), description = text(editorial.descriptionKey);
	const highlights = editorial.highlights.map((item) => ({ illustration: item.illustration, title: text(item.titleKey), description: text(item.descriptionKey) }))
		.filter((item) => item.title && item.description);
	return headline && description && highlights.length ? { headline, description, highlights } : null;
}
