import assert from "node:assert/strict";
import test from "node:test";
import { freshStores, stubBridgeWindow } from "./testHarness";
import { createAnnotation } from "../lib/screenshot/annotationModel";

test("save still reaches the native bridge on the second capture of a session", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();

	const { screenshotEditor, initScreenshotEditor } = await loadStore(
		"/src/stores/screenshotEditor.svelte.ts",
	);
	initScreenshotEditor();

	const receive = (msg: Record<string, unknown>): void => {
		(window as { __lilo?: { receive(msg: unknown): void } }).__lilo?.receive(msg);
	};
	const captured = {
		event: "screenshotCaptured",
		id: "capture-1",
		url: "lilo-chrome://ui/screenshot/capture-1.png",
		filename: "screenshot-example.com.png",
		host: "example.com",
	};

	// The editor component mounts once for the whole app session and registers
	// its flattener a single time; captures come and go around it.
	screenshotEditor.registerFlattener(async () => "data:image/png;base64,FLAT=");

	// First capture: save reaches the bridge.
	receive(captured);
	await screenshotEditor.save();
	assert.equal(posted.filter((m) => m.action === "screenshot.saveDefault").length, 1);

	// Native confirms the write, which closes the editor.
	receive({ event: "screenshotSaved", path: "/Users/me/Downloads/screenshot-example.com.png" });
	assert.equal(screenshotEditor.open, false);

	// Second capture in the same session: save must still work.
	receive(captured);
	await screenshotEditor.save();
	assert.equal(posted.filter((m) => m.action === "screenshot.saveDefault").length, 2);

	screenshotEditor.clearToast();
});

test("save leaves an unannotated capture to native and flattens an annotated one", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();

	const { screenshotEditor, initScreenshotEditor } = await loadStore(
		"/src/stores/screenshotEditor.svelte.ts",
	);
	initScreenshotEditor();
	(window as { __lilo?: { receive(msg: unknown): void } }).__lilo?.receive({
		event: "screenshotCaptured",
		id: "capture-1",
		url: "lilo-chrome://ui/screenshot/capture-1.png",
		filename: "shot.png",
		host: "example.com",
	});
	let flattened = 0;
	screenshotEditor.registerFlattener(async () => {
		flattened += 1;
		return "data:image/png;base64,FLAT=";
	});
	const saves = () => posted.filter((m) => m.action === "screenshot.saveDefault").map((m) => m.payload);

	screenshotEditor.setCrop({ x: 10, y: 20, w: 300, h: 400 });
	await screenshotEditor.save();
	assert.deepEqual(saves()[0], { id: "capture-1", crop: { x: 10, y: 20, w: 300, h: 400 }, filename: "shot.png" });
	assert.equal(flattened, 0);

	screenshotEditor.commit([createAnnotation("rect", { x: 0, y: 0, w: 50, h: 50 }, "#ff3b30", 4)]);
	await screenshotEditor.save();
	assert.deepEqual(saves()[1], { id: "capture-1", dataURL: "data:image/png;base64,FLAT=", filename: "shot.png" });
	assert.equal(flattened, 1);

	screenshotEditor.clearToast();
});

test("a capture cut at the height limit says so", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const { screenshotEditor, initScreenshotEditor } = await loadStore(
		"/src/stores/screenshotEditor.svelte.ts",
	);
	initScreenshotEditor();
	const receive = (truncated: boolean): void => {
		(window as { __lilo?: { receive(msg: unknown): void } }).__lilo?.receive({
			event: "screenshotCaptured",
			id: "capture-1",
			url: "lilo-chrome://ui/screenshot/capture-1.png",
			filename: "shot.png",
			host: "example.com",
			truncated,
		});
	};

	receive(false);
	assert.equal(screenshotEditor.toast, null);

	receive(true);
	assert.equal(screenshotEditor.toast?.kind, "notice");

	screenshotEditor.clearToast();
});

test("a full-page capture shows a loader, and closing it drops the late result", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const { screenshotEditor, initScreenshotEditor } = await loadStore(
		"/src/stores/screenshotEditor.svelte.ts",
	);
	initScreenshotEditor();
	const receive = (msg: Record<string, unknown>): void => {
		(window as { __lilo?: { receive(msg: unknown): void } }).__lilo?.receive(msg);
	};
	const captured = (id: string) => ({
		event: "screenshotCaptured",
		id,
		url: `lilo-chrome://ui/screenshot/${id}.png`,
		filename: "shot.png",
		host: "example.com",
	});

	receive({ event: "screenshotCapturing" });
	assert.equal(screenshotEditor.open, true);
	assert.equal(screenshotEditor.loading, true);
	receive(captured("capture-1"));
	assert.equal(screenshotEditor.loading, true, "still loading until the image is decoded");
	screenshotEditor.imageReady();
	assert.equal(screenshotEditor.loading, false);
	assert.equal(screenshotEditor.captured?.id, "capture-1");

	receive({ event: "screenshotCapturing" });
	screenshotEditor.cancel();
	receive(captured("capture-2"));
	assert.equal(screenshotEditor.open, false);
	assert.deepEqual(posted.filter((m) => m.action === "screenshot.cancel").at(-1)?.payload, { id: "capture-2" });

	receive(captured("capture-3"));
	assert.equal(screenshotEditor.open, true, "only the abandoned capture is dropped");
});

test("a save the editor did not ask for, from a capture's card, leaves it open", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const { screenshotEditor, initScreenshotEditor } = await loadStore("/src/stores/screenshotEditor.svelte.ts");
	initScreenshotEditor();
	const receive = (msg: Record<string, unknown>): void => {
		(window as { __lilo?: { receive(msg: unknown): void } }).__lilo?.receive(msg);
	};

	receive({ event: "screenshotCaptured", id: "capture-1", url: "lilo-chrome://ui/screenshot/capture-1.png", filename: "a.png" });
	receive({ event: "screenshotSaved", path: "/Users/me/Downloads/b.png" });

	assert.equal(screenshotEditor.open, true);
	assert.equal(screenshotEditor.toast?.kind, "saved");
	screenshotEditor.clearToast();
});
