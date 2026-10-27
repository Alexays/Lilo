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
}
