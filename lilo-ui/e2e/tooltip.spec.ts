import { expect, test } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("a tooltip that would start just inside the left edge lands on the window margin", async ({ page }) => {
	await bootChrome(page, initialWorld());

	const left = await page.evaluate(async () => {
		const { tooltip } = await import("/src/lib/tooltip.ts");
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
