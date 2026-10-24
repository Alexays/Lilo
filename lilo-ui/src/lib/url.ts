/** Lowercased host (with port) of a URL, `www.` stripped; null when unparsable. */
export function hostOf(url: string | undefined): string | null {
	if (!url || !url.trim()) return null;
	const candidate = url.includes("://") ? url : `https://${url}`;
	try {
		const parsed = new URL(candidate).host.toLowerCase();
		const cleaned = parsed.startsWith("www.") ? parsed.slice(4) : parsed;
		return cleaned || null;
	} catch {
		return null;
	}
}

/** Compare URLs ignoring scheme-less input, case, trailing slash and fragment. */
export function normalizeURLForMatch(url: string): string {
	const candidate = url.includes("://") ? url : `https://${url}`;
	try {
		const parsed = new URL(candidate);
		parsed.hash = "";
		let normalized = parsed.toString().toLowerCase();
		if (normalized.endsWith("/")) normalized = normalized.slice(0, -1);
		return normalized;
	} catch {
		return url.toLowerCase();
	}
}
