// Model for the URL-bar site-permissions popover: origin keying and row derivation over
// the sitePermissionsLoaded snapshot.

import type { BridgeSitePermissionSnapshot } from "./bridge/protocol";

const SITE_PERMISSION_TYPES = [
	"camera",
	"microphone",
	"location",
	"notifications",
] as const;

type SitePermissionType = (typeof SITE_PERMISSION_TYPES)[number];

interface SitePermissionRow {
	type: SitePermissionType;
	state: "allowed" | "blocked" | "ask";
	/** Stored record id, present only when a decision exists (enables reset). */
	id?: string;
}

/**
 * Must match Swift's PermissionOriginKey: scheme://host, plus the port when non-default. Empty for URLs without a
 * host (about:, data:, ...).
 */
export function permissionOriginFromURL(url: string): string {
	try {
		const parsed = new URL(url);
		if (!parsed.hostname) return "";
		// URL.host already omits the scheme-default port.
		return `${parsed.protocol}//${parsed.host}`;
	} catch {
		return "";
	}
}

/** One row per permission type for `origin`; a type with no stored decision reads "ask". */
export function sitePermissionRows(
	permissions: BridgeSitePermissionSnapshot[],
	origin: string,
): SitePermissionRow[] {
	return SITE_PERMISSION_TYPES.map((type) => {
		const record = permissions.find(
			(permission) => permission.origin === origin && permission.type === type,
		);
		if (!record) return { type, state: "ask" };
		return {
			type,
			state: record.decision === "allow" ? "allowed" : "blocked",
			id: record.id,
		};
	});
}
