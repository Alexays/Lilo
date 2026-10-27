import { expect, test } from "@playwright/test";
import type { FrameLocator, Page } from "@playwright/test";

const openSettings = async (page: Page) => {
  const menu = page.locator("#browser-demo .mac-menu").first();
  await menu.locator(":scope > summary").click();
  await menu.locator("[data-action=settings]").click();
};

const imagesLoaded = (frame: FrameLocator) =>
  frame.locator("body").evaluate((body) => {
    const images = [...body.querySelectorAll("img")];

    return (
      images.length > 0 &&
      images.every((image) => image.complete && image.naturalWidth > 0)
    );
  });

for (const french of [false, true]) {
  test(`native app, site, agent and setup images load with production headers (${french ? "French mobile" : "English desktop"})`, async ({
    page,
  }, info) => {
    const failed: string[] = [];
    page.on("response", (response) => {
      if (response.status() >= 400) {
        failed.push(`${response.status()} ${response.url()}`);
      }
    });
    page.on("pageerror", (error) => failed.push(error.message));

    if (french) {
      await page.setViewportSize({ height: 851, width: 390 });
    }

    await page.goto(`${french ? "/fr/" : "/"}#browser-demo`);
    const frame = page.frameLocator("#browser-demo iframe");
    await expect(frame.locator(".repo-top img")).toBeVisible();
    await expect.poll(() => imagesLoaded(frame)).toBe(true);
    await expect(frame.locator(".ext-icon-image")).toHaveCount(2);
    await expect(
      frame.locator(".tab-item .site-favicon.is-fallback")
    ).toHaveCount(0);
    await expect(page.locator("#browser-demo .menu-flower svg")).toBeVisible();
    await openSettings(page);
    await frame
      .locator(".section-nav-button", {
        hasText: french ? "Apparence" : "Appearance",
      })
      .click();

    const icons = frame.getByRole("radiogroup", {
      exact: true,
      name: french ? "Icône de l'app" : "App icon",
    });

    await expect(icons.getByRole("radio")).toHaveCount(11);
    await expect.poll(() => imagesLoaded(frame)).toBe(true);
    await expect(
      icons.getByRole("radio", {
        exact: true,
        name: french ? "Classique" : "Classic",
      })
    ).toHaveAttribute("aria-checked", "true");
    await icons
      .getByRole("radio", { exact: true, name: french ? "Nuit" : "Night" })
      .click();
    await expect(
      icons.getByRole("radio", { exact: true, name: french ? "Nuit" : "Night" })
    ).toHaveAttribute("aria-checked", "true");
    await page
      .locator("#browser-demo")
      .screenshot({ path: info.outputPath("native-icons.png") });
    await page.locator("#browser-demo .demo-modes [data-action=mcp]").click();
    await expect(frame.locator(".codex-mark")).toBeVisible();
    await expect.poll(() => imagesLoaded(frame)).toBe(true);
    await openSettings(page);
    await frame
      .locator(".section-nav-button", {
        hasText: "Extensions",
      })
      .click();

    const manager = frame.locator(".ui-list-row").filter({
      hasText: french
        ? /gestionnaire de mots de passe/iu
        : /password manager/iu,
    });

    await manager.getByRole("button").click();
    await expect(frame.locator(".managers img.logo")).toHaveCount(7);
    await expect.poll(() => imagesLoaded(frame)).toBe(true);
    await expect(frame.locator(".managers .glyph")).toHaveCount(0);
    expect(failed).toEqual([]);
  });
}
