import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("the address drags out as a link", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const trigger = page.locator(".url-trigger");
	await expect(trigger).toHaveAttribute("draggable", "true");

	const dragged = await trigger.evaluate((el) => {
		const dataTransfer = new DataTransfer();
		el.dispatchEvent(new DragEvent("dragstart", { dataTransfer, bubbles: true }));
		return { uri: dataTransfer.getData("text/uri-list"), text: dataTransfer.getData("text/plain") };
	});
	expect(dragged.uri).toMatch(/^https?:\/\//);
	expect(dragged.text).toBe(dragged.uri);
});
