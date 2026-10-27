import { expect, test } from "@playwright/test";

for (const route of [
  "",
  "moving/",
  "arc-alternative/",
  "ai-agents/",
  "changelog/",
]) {
  test(`French browsers land on the matching French page (${route || "home"})`, async ({
    browser,
  }) => {
    const context = await browser.newContext({ locale: "fr-CA" });

    try {
      const page = await context.newPage();
      await page.goto(
        `http://127.0.0.1:8788/${route}?from=example#main-content`
      );
      await expect(page).toHaveURL(
        `http://127.0.0.1:8788/fr/${route}?from=example#main-content`
      );
      await expect(page.locator("html")).toHaveAttribute("lang", "fr");
      await page.locator("#site-navigation a").first().click();
      await expect(page).toHaveURL("http://127.0.0.1:8788/fr/moving/");
    } finally {
      await context.close();
    }
  });
}

for (const locale of ["en-US", "de-DE"]) {
  test(`English is the fallback and French URLs stay accessible (${locale})`, async ({
    browser,
  }) => {
    const context = await browser.newContext({ locale });

    try {
      const page = await context.newPage();
      await page.goto("http://127.0.0.1:8788/moving/");
      await expect(page.locator("html")).toHaveAttribute("lang", "en");
      await expect(page).toHaveURL("http://127.0.0.1:8788/moving/");
      await page.goto("http://127.0.0.1:8788/fr/moving/");
      await expect(page.locator("html")).toHaveAttribute("lang", "fr");
      await expect(page).toHaveURL("http://127.0.0.1:8788/fr/moving/");
    } finally {
      await context.close();
    }
  });
}

test("language selection respects the order of supported browser preferences", async ({
  page,
}) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "languages", {
      get: () => ["de-DE", "en-GB", "fr-FR"],
    });
  });
  await page.goto("/");
  await expect(page.locator("html")).toHaveAttribute("lang", "en");
  await page.reload();
  await expect(page).toHaveURL("http://127.0.0.1:8788/");
});
