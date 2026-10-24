import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

// A capture with a real size, so the editor lays out a canvas to draw on.
const IMAGE = `data:image/svg+xml,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="800" height="500"><rect width="800" height="500" fill="#ddd"/></svg>')}`;

async function openEditor(page: Page): Promise<void> {
	await bootChrome(page, initialWorld());
	await page.evaluate((url) => window.__lilo!.receive({ event: "screenshotCaptured", id: "shot", url, filename: "shot.png" }), IMAGE);
	await page.locator(".screenshot-editor .canvas img.base").waitFor();
	// The canvas lifts off into place: a point read off its box before it lands can miss it.
	await page.locator(".screenshot-editor .canvas").evaluate((canvas) => Promise.all(canvas.getAnimations().map((animation) => animation.finished)));
}

test("Save and Copy wait for the capture to arrive", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "screenshotCapturing" }));
	const panel = page.locator(".screenshot-panel");
	const save = panel.getByRole("button", { name: "Save", exact: true });
	const copy = panel.getByRole("button", { name: "Copy" });
	await expect(panel.locator(".save-group button").first()).toBeVisible();

	for (const button of [save, panel.getByRole("button", { name: "Save options" }), copy]) {
		await expect(button).toBeDisabled();
	}

	await page.evaluate((url) => window.__lilo!.receive({ event: "screenshotCaptured", id: "shot", url, filename: "shot.png" }), IMAGE);
	await save.click();
	expect((await sentCommands(page)).map((command) => command.action)).toContain("screenshot.saveDefault");
});

test("Escape closes the save menu and keeps the capture", async ({ page }) => {
	await openEditor(page);
	await page.locator('.screenshot-panel [aria-label="Save options"]').click();
	await expect(page.locator(".save-menu")).toBeVisible();

	await page.keyboard.press("Escape");

	await expect(page.locator(".save-menu")).toHaveCount(0);
	await expect(page.locator(".screenshot-editor .canvas")).toBeVisible();
	expect((await sentCommands(page)).map((command) => command.action)).not.toContain("screenshot.cancel");
});

test("the saved notice sits over the page, clear of a narrow window's sidebar", async ({ page }) => {
	await page.setViewportSize({ width: 600, height: 400 });
	await openEditor(page);
	await page.evaluate(() => {
		document.documentElement.style.setProperty("--sidebar-width", "200px");
		window.__lilo!.receive({ event: "screenshotSaved", path: "/Users/someone/Desktop/Screenshot 2026-10-23 at 16.00.00.png" });
	});

	const box = (await page.locator(".screenshot-toast").boundingBox())!;
	const sidebar = (await page.locator(".sidebar").boundingBox())!;
	expect(box.x).toBeGreaterThanOrEqual(sidebar.x + sidebar.width);
	expect(box.x + box.width).toBeLessThanOrEqual(600);
});

test("the crop frame's handles and Apply take the Space's accent", async ({ page }) => {
	await openEditor(page);
	await page.keyboard.press("c");
	const canvas = (await page.locator(".screenshot-editor .canvas").boundingBox())!;
	await page.mouse.move(canvas.x + 40, canvas.y + 40);
	await page.mouse.down();
	await page.mouse.move(canvas.x + 300, canvas.y + 200, { steps: 6 });
	await page.mouse.up();

	const colors = await page.evaluate(() => {
		const probe = document.createElement("div");
		probe.style.color = "var(--sidebar-accent)";
		document.body.appendChild(probe);
		const accent = getComputedStyle(probe).color;
		probe.remove();
		return {
			accent,
			apply: getComputedStyle(document.querySelector(".crop-btn.apply")!).backgroundColor,
			handle: getComputedStyle(document.querySelector(".sel-handle")!).borderTopColor,
		};
	});
	expect(colors.apply).toBe(colors.accent);
	expect(colors.handle).toBe(colors.accent);
});

test("a layer row is reached with Tab and selected with Enter", async ({ page }) => {
	await openEditor(page);
	await page.keyboard.press("r");
	const canvas = (await page.locator(".screenshot-editor .canvas").boundingBox())!;
	await page.mouse.move(canvas.x + 50, canvas.y + 50);
	await page.mouse.down();
	await page.mouse.move(canvas.x + 200, canvas.y + 150, { steps: 6 });
	await page.mouse.up();
	const layer = page.locator(".screenshot-panel .layer").first();
	await expect(layer).toBeVisible();

	await page.locator(".screenshot-panel .tool").first().focus();
	for (let i = 0; i < 40 && !(await layer.evaluate((el) => el === document.activeElement)); i++) await page.keyboard.press("Tab");
	await expect(layer).toBeFocused();
	await page.keyboard.press("Enter");
	await expect(layer).toHaveClass(/active/);
});

test("the drawing tools take their shortcuts", async ({ page }) => {
	await openEditor(page);
	const pressed = page.locator('.screenshot-panel .tool[aria-pressed="true"]');

	for (const [key, label] of [["p", "Pen"], ["o", "Ellipse"], ["r", "Rectangle"], ["t", "Text"], ["a", "Arrow"], ["v", "Select"]]) {
		await page.keyboard.press(key);
		await expect(pressed).toHaveAttribute("aria-label", label);
	}
});

test("an arrow takes the line style and heads set in the panel", async ({ page }) => {
	await openEditor(page);
	await page.keyboard.press("a");
	await page.locator('.screenshot-panel [aria-label="Dashed"]').click();
	await page.locator('.screenshot-panel [aria-label="At both ends"]').click();

	const canvas = (await page.locator(".screenshot-editor .canvas").boundingBox())!;
	await page.mouse.move(canvas.x + canvas.width * 0.2, canvas.y + canvas.height * 0.5);
	await page.mouse.down();
	await page.mouse.move(canvas.x + canvas.width * 0.7, canvas.y + canvas.height * 0.5, { steps: 6 });
	await page.mouse.up();

	const paths = page.locator(".screenshot-editor .anno-layer path");
	await expect(paths).toHaveCount(2);
	await expect(paths.first()).toHaveAttribute("stroke-dasharray", /\d/);
	expect((await paths.nth(1).getAttribute("d"))!.split("M").length - 1).toBe(2);
});

test("a pen stroke grows with the pointer and stays once drawn", async ({ page }) => {
	await openEditor(page);
	await page.keyboard.press("p");
	const path = page.locator(".screenshot-editor .anno-layer path");
	const curves = async () => ((await path.getAttribute("d")) ?? "").split("Q").length - 1;

	const canvas = (await page.locator(".screenshot-editor .canvas").boundingBox())!;
	await page.mouse.move(canvas.x + 40, canvas.y + 40);
	await page.mouse.down();
	// One move per frame: moves within a frame coalesce into a single point.
	for (let step = 1; step <= 6; step += 1) {
		await page.mouse.move(canvas.x + 40 + step * 30, canvas.y + 40 + (step % 2) * 25);
		await page.evaluate(() => new Promise(requestAnimationFrame));
		await expect.poll(curves).toBe(Math.max(0, step - 1));
	}
	await page.mouse.up();

	await expect(path).toHaveCount(1);
	expect(await curves()).toBe(5);
});

test("a rectangle takes the fill from the panel", async ({ page }) => {
	await openEditor(page);
	await page.keyboard.press("r");
	await expect(page.locator('.screenshot-panel [aria-label="Tinted"]')).toBeVisible();
	await page.locator('.screenshot-panel [aria-label="Tinted"]').click();

	const canvas = (await page.locator(".screenshot-editor .canvas").boundingBox())!;
	await page.mouse.move(canvas.x + 50, canvas.y + 50);
	await page.mouse.down();
	await page.mouse.move(canvas.x + 200, canvas.y + 150, { steps: 6 });
	await page.mouse.up();

	await expect(page.locator(".screenshot-editor .anno-layer rect").first()).toHaveAttribute("fill-opacity", "0.16");
});
