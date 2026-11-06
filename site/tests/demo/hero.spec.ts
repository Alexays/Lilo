import { expect, test } from "@playwright/test";

const command = "brew install --cask alexays/tap/lilo";

for (const lang of ["en", "fr"] as const) {
  const home = lang === "fr" ? "/fr/" : "/";

  test(`Homebrew command copies from the keyboard (${lang})`, async ({
    page,
  }) => {
    await page.addInitScript(() => {
      Object.defineProperty(navigator, "clipboard", {
        value: {
          writeText: (value: string) => {
            sessionStorage.setItem("copied-command", value);

            return Promise.resolve();
          },
        },
      });
    });
    await page.goto(home);
    const input = page.locator("#hero .brew-command input");
    const copy = page.locator("#hero .copy-command");
    await input.focus();
    await page.keyboard.press("Tab");
    await expect(copy).toBeFocused();
    await page.keyboard.press("Enter");
    await expect
      .poll(() => page.evaluate(() => sessionStorage.getItem("copied-command")))
      .toBe(command);
    await expect(page.locator("#hero .copy-status")).toHaveText(
      lang === "fr" ? "Commande copiée" : "Command copied"
    );
    await expect(copy.locator(".check-icon")).toBeVisible();
  });

  test(`Homebrew command remains selectable when clipboard access fails (${lang})`, async ({
    page,
  }) => {
    await page.addInitScript(() => {
      Object.defineProperty(navigator, "clipboard", {
        value: {
          writeText: () => Promise.reject(new Error("Clipboard unavailable")),
        },
      });
    });
    await page.goto(home);
    await page.locator("#hero .copy-command").click();
    const input = page.locator("#hero .brew-command input");
    await expect(input).toBeFocused();
    await expect
      .poll(() =>
        input.evaluate((element: HTMLInputElement) =>
          element.value.slice(
            element.selectionStart ?? 0,
            element.selectionEnd ?? 0
          )
        )
      )
      .toBe(command);
    await expect(page.locator("#hero .copy-status")).toContainText(
      lang === "fr" ? "Échec de la copie" : "Copy failed"
    );
  });

  test(`hero links and install command work without JavaScript (${lang})`, async ({
    browser,
  }) => {
    const context = await browser.newContext({
      javaScriptEnabled: false,
      viewport: { height: 844, width: 390 },
    });

    try {
      const page = await context.newPage();
      await page.goto(`http://127.0.0.1:8788${home}`);
      await expect(page.locator("#home-heading")).toBeVisible();
      await expect(page.locator("#hero .copy-command")).toBeHidden();
      await expect(page.locator("#hero .brew-command input")).toHaveValue(
        command
      );
      await expect(
        page.locator("#hero .install-actions .download-button")
      ).toHaveAttribute(
        "href",
        "https://github.com/Alexays/Lilo/releases/latest/download/Lilo.dmg"
      );
      await page.locator("#hero .release-link").click();
      const release = page.locator(".release").first();
      await expect(release).toBeInViewport();
      expect(new URL(page.url()).hash).toBe(
        `#${await release.getAttribute("id")}`
      );
    } finally {
      await context.close();
    }
  });

  test(`home heading ends with the logo, other pages keep plain text (${lang})`, async ({
    page,
  }) => {
    await page.goto(home);
    const heading = page.locator("#home-heading");
    await expect(heading).toHaveText(
      lang === "fr" ? "Votre internet, en fleur." : "Your internet, in bloom."
    );
    await expect(heading.locator(".hero-stop svg")).toBeVisible();

    await page.goto(`${home}moving/`);
    await expect(page.locator(".page-hero h1")).toBeVisible();
    await expect(page.locator(".page-hero .hero-stop")).toHaveCount(0);
  });

  test(`hero demo starts by itself after the page loads (${lang})`, async ({
    page,
  }) => {
    await page.goto(home);
    const poster = page.locator("#browser-demo .demo-poster");
    await expect(poster).toBeHidden();
    await expect(
      page.frameLocator("#browser-demo iframe").locator(".repo-top")
    ).toBeVisible();

    const timing = await page.evaluate(() => {
      const loaded = performance
        .getEntriesByType("navigation")
        .find((entry) => entry instanceof PerformanceNavigationTiming);

      return performance
        .getEntriesByType("resource")
        .filter((entry) => new URL(entry.name).pathname.startsWith("/demo/"))
        .map((entry) => entry.startTime - (loaded?.loadEventEnd ?? Infinity));
    });

    expect(timing.length).toBeGreaterThan(0);
    expect(timing.every((delay) => delay >= 0)).toBe(true);
  });

  test(`keyboard skips the hero demo (${lang})`, async ({ page }) => {
    await page.goto(home);
    const skip = page.locator("#browser-demo .skip-link");
    await skip.focus();
    await expect(skip).toBeVisible();
    await page.keyboard.press("Enter");

    await page.keyboard.press("Tab");
    expect(
      await page.evaluate(() =>
        Boolean(document.activeElement?.closest("#native"))
      )
    ).toBe(true);
  });
}

test("opening a hero demo menu reaches the live demo", async ({ page }) => {
  await page.goto("/");
  const menu = page.locator("#browser-demo .mac-menu").first();
  await menu.locator(":scope > summary").click();
  await expect(page.locator("#browser-demo .demo-poster")).toBeHidden();
  await expect(menu.locator("[data-action='settings']")).toBeEnabled();
});
