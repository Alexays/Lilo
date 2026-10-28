import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

test("a release request is retained before the sheet loads and duplicates do not replace it", async () => {
	const posted = stubBridgeWindow();
	const load = await freshStores();
	const store = await load("/src/stores/whatsNew.svelte.ts");
	store.initWhatsNewStore();
	const receive = window.__lilo!.receive;
	receive({ event: "openWhatsNew", version: "1.2.3", automatic: true });
	receive({ event: "openWhatsNew", version: "1.2.4", automatic: false });
	assert.deepEqual(store.getWhatsNewRequest(), { event: "openWhatsNew", version: "1.2.3", automatic: true });
	store.closeWhatsNew();
	store.closeWhatsNew();
	assert.equal(store.getWhatsNewRequest(), null);
	assert.equal(posted.filter((message) => message.action === "dismissWhatsNew").length, 1);
});
