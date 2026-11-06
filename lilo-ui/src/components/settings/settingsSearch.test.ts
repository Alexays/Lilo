import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "../../stores/testHarness";

type LiloWindow = {
  window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
};

function receive(msg: Record<string, unknown>): void {
  (globalThis as unknown as LiloWindow).window.__lilo?.receive(msg);
}

test("sites match on their host and on what they hold, and follow the stores", async () => {
  stubBridgeWindow();
  const loadStore = await freshStores();
  const settings = await loadStore("/src/stores/settings.svelte.ts");
  const panels = await loadStore("/src/stores/panels.svelte.ts");
  const search = await loadStore("/src/components/settings/settingsSearch.svelte.ts");
  settings.initSettingsStore();
  receive({
    event: "sitePermissionsLoaded",
    permissions: [{ id: "1", origin: "https://meet.example.com", type: "camera", decision: "allow", updatedAt: 1 }],
  });
  receive({ event: "websiteDataLoaded", sites: [{ name: "example.com", kinds: ["cookies"] }] });
  receive({ event: "zoomLevelsLoaded", levels: [{ host: "docs.example.org", zoom: 1.25 }] });
  const siteKeys = (query: string) => {
    panels.setSettingsQuery(query);
    return search.getSettingsSearchResults().sites.map((site: { key: string }) => site.key);
  };

  assert.deepEqual(siteKeys("  "), []);
  assert.deepEqual(siteKeys("CAMÉRA"), ["example.com"]);
  assert.deepEqual(siteKeys("example"), ["docs.example.org", "example.com"]);
  assert.deepEqual(siteKeys("example org"), ["docs.example.org"]);

  receive({
    event: "sitePermissionsLoaded",
    permissions: [{ id: "2", origin: "https://www.example.net", type: "microphone", decision: "deny", updatedAt: 2 }],
  });
  assert.deepEqual(siteKeys("camera"), []);
  assert.deepEqual(siteKeys("microphone"), ["example.net"]);
});
