import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("the pip dock slot mounts on the bridge event and registers its zone", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());

	await expect(page.locator(".pip-dock")).toHaveCount(0);

	await page.evaluate((msg) => window.__lilo!.receive(msg), {
		event: "pipDockChanged",
		active: true,
		title: "Weekly sync",
	});

	const slot = page.locator(".pip-dock");
	await expect(slot).toBeVisible();
	await expect(slot).toHaveAttribute("title", "Weekly sync");

	await expect
		.poll(async () =>
			(await sentCommands(page)).some(
				(c) =>
					c.action === "registerInteractiveZones" &&
					(c.payload.zones as { id: string }[] | undefined)?.some((zone) => zone.id === "pip-dock"),
			),
		)
		.toBe(true);

	await page.evaluate((msg) => window.__lilo!.receive(msg), {
		event: "pipDockChanged",
		active: false,
	});
	await expect(page.locator(".pip-dock")).toHaveCount(0);
});
