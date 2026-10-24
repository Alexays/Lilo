import assert from "node:assert/strict";
import test from "node:test";

import {
  extensionPermissionLines,
  permissionRequestIcon,
  sitePermissionAskKey,
} from "./urlBarDrawerModel";

const siteRequest = (type: string) => ({
  kind: "sitePermission" as const,
  requestId: "r",
  tabId: "t",
  type,
  origin: "meet.example.com",
});

test("site requests ask in plain language and fall back for unknown kinds", () => {
  assert.equal(sitePermissionAskKey("camera"), "permissionPrompt.asks.camera");
  assert.equal(sitePermissionAskKey("camera and microphone"), "permissionPrompt.asks.cameraAndMicrophone");
  assert.equal(sitePermissionAskKey("media"), "permissionPrompt.asks.media");
  assert.equal(permissionRequestIcon(siteRequest("microphone")), "microphone");
  assert.equal(permissionRequestIcon(siteRequest("media")), "camera");
  assert.equal(permissionRequestIcon({ kind: "agentControl", requestId: "1", clientName: "Codex", executable: "", profileName: "" }), "agent");
});

test("extension permissions translate known names and keep unknown ones raw", () => {
  const request = {
    kind: "extensionPermission" as const,
    requestId: "r",
    spaceId: "s",
    extensionName: "1Password",
    permissions: ["tabs", "fontSettings"],
    origins: ["<all_urls>", "*://*/*", "https://example.com/*"],
    type: "permissions" as const,
  };
  const catalog: Record<string, string> = {
    "permissionPrompt.permissions.tabs": "See your open tabs",
    "permissionPrompt.allSites": "All websites",
  };
  const resolve = (key: string) => catalog[key] ?? key;

  assert.deepEqual(extensionPermissionLines(request, resolve), ["See your open tabs", "fontSettings", "All websites", "https://example.com/*"]);
  assert.deepEqual(extensionPermissionLines({ ...request, type: "urls", origins: ["https://example.com/"] }, resolve), ["https://example.com/"]);
  assert.equal(permissionRequestIcon(request), "extension");
});
