import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("a tooltip that would start just inside the left edge lands on the window margin", async ({ page }) => {
	await bootChrome(page, initialWorld());

	const left = await page.evaluate(async () => {
		// A URL the dev server serves to the page, not a path TypeScript resolves.
		const url = "/src/lib/tooltip.ts";
		const { tooltip }: typeof import("../src/lib/tooltip") = await import(url);
		const text = "A tooltip wide enough to need clamping";
		const anchor = document.createElement("button");
		anchor.style.cssText = "position: fixed; top: 300px; width: 2px; height: 2px; padding: 0; border: 0;";
		document.body.appendChild(anchor);
		const shown = async (centerX: number): Promise<DOMRect> => {
			anchor.style.left = `${centerX - 1}px`;
			const action = tooltip(anchor, { text, delay: 0 });
			anchor.dispatchEvent(new MouseEvent("mouseenter"));
			await new Promise((resolve) => setTimeout(resolve, 50));
			const rect = document.querySelector(".lilo-tooltip")!.getBoundingClientRect();
			action.destroy();
			return rect;
		};
		const { width } = await shown(600);
		// Centred there, the tip would start 8px from the edge: inside the 16px margin, not past it.
		return (await shown(width / 2 + 8)).left;
	});

	expect(left).toBeCloseTo(16, 0);
});

test("a right-click hides the tooltip: the native menu that opens never sends a mouseleave", async ({ page }) => {
	await bootChrome(page, initialWorld());

	const remaining = await page.evaluate(async () => {
		const url = "/src/lib/tooltip.ts";
		const { tooltip }: typeof import("../src/lib/tooltip") = await import(url);
		const anchor = document.createElement("button");
		document.body.appendChild(anchor);
		const action = tooltip(anchor, { text: "Space", delay: 0 });
		anchor.dispatchEvent(new MouseEvent("mouseenter"));
		await new Promise((resolve) => setTimeout(resolve, 50));
		anchor.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true }));
		await new Promise((resolve) => setTimeout(resolve, 200));
		const count = document.querySelectorAll(".lilo-tooltip").length;
		action.destroy();
		return count;
	});

	expect(remaining).toBe(0);
});
