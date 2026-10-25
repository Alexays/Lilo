import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";

test("the content's right edge follows the side panel", async () => {
	stubBridgeWindow({ document: true });
	const properties = new Map<string, string>();
	(globalThis as { document: { documentElement?: unknown } }).document.documentElement = {
		style: {
			setProperty: (name: string, value: string) => properties.set(name, value),
			removeProperty: (name: string) => properties.delete(name),
		},
	};
	const loadStore = await freshStores();
	const { initSidePanelStore } = await loadStore("/src/stores/sidePanel.ts");
	initSidePanelStore();
	const receive = (width: number) =>
		(globalThis as { window: { __lilo: { receive(msg: unknown): void } } }).window.__lilo.receive({ event: "sidePanelWidthChanged", width });

	receive(368);
	assert.equal(properties.get("--side-panel-width"), "368px");

	receive(0);
	assert.equal(properties.has("--side-panel-width"), false, "a closed panel gives the edge back to the stylesheet");
});
