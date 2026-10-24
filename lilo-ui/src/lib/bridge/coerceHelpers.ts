// Hand-written coerce primitives shared between coerce.ts and tabProtocol.gen.ts.
// Do not import from coerce.ts here: this file is the bottom of the import tree.
import { DEFAULT_TAB_TITLE } from "./defaults";

export function fallbackTabTitle(url: string | undefined): string {
	const normalizedURL = url?.trim() ?? "";
	if (!normalizedURL) return DEFAULT_TAB_TITLE;
	try {
		const parsedURL = new URL(normalizedURL);
		const path = parsedURL.pathname === "/" ? "" : parsedURL.pathname;
		return `${parsedURL.hostname}${path}${parsedURL.search}${parsedURL.hash}`;
	} catch {
		return normalizedURL;
	}
}

/** Host + path (no search/hash) for tooltip subtitles; empty when there is no URL. */
export function tooltipTabURL(url: string | undefined): string {
	if (!url) return "";
	try {
		const parsedURL = new URL(url);
		const path = parsedURL.pathname === "/" ? "" : parsedURL.pathname;
		return `${parsedURL.hostname}${path}`;
	} catch {
		return url;
	}
}

export function normalizeTabTitle(title: string | undefined, url: string | undefined): string {
	const normalizedTitle = title?.trim() ?? "";
	return normalizedTitle || fallbackTabTitle(url);
}

const HEX_COLOR_RE = /^#[0-9A-Fa-f]{6}$/;

/** Trimmed string, or undefined when empty/absent. */
export function coerceTrimmedOptional(value: string | undefined): string | undefined {
	return value?.trim() || undefined;
}

/** Valid #RRGGBB hex color, or undefined. */
export function coerceHexColor(value: string | undefined): string | undefined {
	const v = value?.trim();
	return v && HEX_COLOR_RE.test(v) ? v : undefined;
}
