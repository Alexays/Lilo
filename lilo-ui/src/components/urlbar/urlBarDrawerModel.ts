// Copy for the address-bar drawers. i18n-free (unit-tested under tsx): it returns catalog keys,
// and `resolve` stands in for t() where a missing key must fall back to the raw value.

import type { PermissionRequest } from "../../stores/urlBarDrawer.svelte";

type DrawerIconName = "camera" | "microphone" | "location" | "notifications" | "extension" | "agent";

// The host reports WebKit's capture kinds by name; anything else falls back to the generic ask.
const SITE_PERMISSION_KINDS: Record<string, DrawerIconName> = {
  camera: "camera",
  microphone: "microphone",
  "camera and microphone": "camera",
  location: "location",
  notifications: "notifications",
};

const ASK_KEYS: Record<string, string> = {
  camera: "permissionPrompt.asks.camera",
  microphone: "permissionPrompt.asks.microphone",
  "camera and microphone": "permissionPrompt.asks.cameraAndMicrophone",
  location: "permissionPrompt.asks.location",
  notifications: "permissionPrompt.asks.notifications",
};

export function permissionRequestIcon(request: PermissionRequest): DrawerIconName {
  if (request.kind === "extensionPermission") return "extension";
  if (request.kind === "agentControl") return "agent";
  return SITE_PERMISSION_KINDS[request.type] ?? "camera";
}

/** Catalog key of the sentence after the origin ("wants to use your camera"). */
export function sitePermissionAskKey(type: string): string {
  return ASK_KEYS[type] ?? "permissionPrompt.asks.media";
}

const ALL_SITES = new Set(["<all_urls>", "*://*/*"]);

/** Plain-language lines for an extension request; unknown permissions keep their API name, sites their pattern. */
export function extensionPermissionLines(
  request: Extract<PermissionRequest, { kind: "extensionPermission" }>,
  resolve: (key: string) => string,
): string[] {
  const permissions = request.type !== "permissions" ? [] : request.permissions.map((permission) => {
    const key = `permissionPrompt.permissions.${permission}`;
    const label = resolve(key);
    return label === key ? permission : label;
  });
  const origins = request.origins.map((origin) => (ALL_SITES.has(origin) ? resolve("permissionPrompt.allSites") : origin));
  return [...permissions, ...new Set(origins)];
}
