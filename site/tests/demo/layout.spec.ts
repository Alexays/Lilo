import { expect, test } from "@playwright/test";
import type { Page } from "@playwright/test";

const routes = ["", "moving/", "arc-alternative/", "ai-agents/", "changelog/"];

const design = (page: Page) =>
  page.evaluate(async () => {
    await document.fonts.ready;

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this callback into the browser's realm.
    const properties = (selector: string, names: string[]) => {
      const element = document.querySelector(selector);

      if (!element) {
        throw new Error(`Missing layout element: ${selector}`);
      }

      const style = getComputedStyle(element);

      return Object.fromEntries(
        names.map((name) => [name, style.getPropertyValue(name)])
      );
    };

    const typography = [
      "font-family",
      "font-size",
      "font-weight",
      "line-height",
      "letter-spacing",
      "max-width",
    ];

    return {
      bottom: properties(".end-content", [
        "padding-top",
        "padding-bottom",
        "padding-left",
        "padding-right",
        "gap",
        "text-align",
      ]),
      bottomHeading: properties(".page-end h2", typography),
      details: properties(".hero-details", [
        "margin-top",
        "gap",
        "grid-template-columns",
        "align-items",
      ]),
      eyebrow: properties(".hero-eyebrow", ["min-height", "align-items"]),
      heading: properties(".page-hero h1", typography),
      section: properties(".band > .page-frame", [
        "padding-top",
        "padding-bottom",
        "padding-left",
        "padding-right",
      ]),
      top: properties(".hero-intro", [
        "padding-top",
        "padding-bottom",
        "padding-left",
        "padding-right",
      ]),
    };
  });

const expectFrames = async (page: Page) => {
  const frames = await page
    .locator(".site-content > section > .page-frame, .foot-frame")
    .evaluateAll((elements) =>
      elements.map((element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);

        return [rect.x, rect.width, style.borderLeft, style.borderRight];
      })
    );

  for (const frame of frames) {
    expect(frame).toEqual(frames[0]);
  }

  const text = await page
    .locator(".hero-content, .foot-brand")
    .evaluateAll((elements) =>
      elements.map((element) => element.getBoundingClientRect().x)
    );

  expect(text[0]).toBe(text[1]);
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth
    )
  ).toBe(true);
  await expect(page.locator(".page-hero")).toHaveCount(1);
  await expect(page.locator(".page-end")).toHaveCount(1);
  await expect(page.locator("main h1")).toHaveCount(1);

  const installers = await page
    .locator(".page-hero .install-panel, .page-end .install-panel")
    .evaluateAll((panels) =>
      panels.map((panel) =>
        [
          ".download-button",
          ".source-link",
          ".brew-command",
          ".brew-command input",
          ".copy-command",
        ].map((selector) => {
          const element = panel.querySelector(selector);

          if (!element) {
            throw new Error(`Missing installer element: ${selector}`);
          }

          const style = getComputedStyle(element);

          return Object.fromEntries(
            [
              "background",
              "color",
              "border",
              "border-radius",
              "padding",
              "font",
              "min-height",
              "gap",
            ].map((property) => [property, style.getPropertyValue(property)])
          );
        })
      )
    );

  expect(installers[0]).toEqual(installers[1]);
  await expect(page.locator(".page-end .tag")).toHaveCount(0);
  await expect(page.locator(".page-end .pixel-logo")).toHaveCount(1);
  await expect(page.locator(".foot-bottom")).toHaveCount(0);
  await expect(page.locator(".foot-nav > div")).toHaveCount(3);
  await expect(
    page.locator('.foot-nav > div:nth-child(2) a[href$="/moving/"]')
  ).toHaveCount(1);
};

for (const lang of ["en", "fr"] as const) {
  const home = lang === "fr" ? "/fr/" : "/";

  for (const width of [390, 768, 1280, 1600]) {
    test(`shared page design cannot drift at ${width}px (${lang})`, async ({
      page,
    }) => {
      await page.setViewportSize({ height: 900, width });
      await page.emulateMedia({ colorScheme: "dark" });
      await page.goto(home);
      const baseline = await design(page);
      await expectFrames(page);

      for (const route of routes.slice(1)) {
        // oxlint-disable-next-line no-await-in-loop -- Compare every route with the same viewport and reference page.
        await page.goto(`${home}${route}`);
        // oxlint-disable-next-line no-await-in-loop
        const current = await design(page);
        expect(current).toEqual(baseline);
        // oxlint-disable-next-line no-await-in-loop
        await expectFrames(page);
        // oxlint-disable-next-line no-await-in-loop
        await expect(page.locator(".hero-preview")).toHaveCount(0);
      }
    });
  }

  test(`shared sections work in light mode and without JavaScript (${lang})`, async ({
    browser,
  }) => {
    const context = await browser.newContext({
      colorScheme: "light",
      javaScriptEnabled: false,
      viewport: { height: 844, width: 390 },
    });

    try {
      const page = await context.newPage();

      for (const route of routes) {
        // oxlint-disable-next-line no-await-in-loop -- Each navigation checks the static document's links and install controls.
        await page.goto(`http://127.0.0.1:8788${home}${route}`);
        // oxlint-disable-next-line no-await-in-loop
        await expectFrames(page);
        // oxlint-disable-next-line no-await-in-loop
        await expect(
          page.locator(".page-hero .brew-command input")
        ).toHaveValue("brew install --cask alexays/tap/lilo");
        // oxlint-disable-next-line no-await-in-loop
        await expect(page.locator(".page-end .copy-command")).toBeHidden();
        // oxlint-disable-next-line no-await-in-loop
        await expect(
          page.locator(".page-end .download-button")
        ).toHaveAttribute(
          "href",
          "https://github.com/Alexays/Lilo/releases/latest/download/Lilo.dmg"
        );
      }
    } finally {
      await context.close();
    }
  });
}

test("the 404 page shares the design and keeps recovery links", async ({
  page,
}) => {
  await page.setViewportSize({ height: 844, width: 390 });
  await page.goto("/");
  const baseline = await design(page);
  await page.goto("/404.html");
  expect(await design(page)).toEqual(baseline);
  await expectFrames(page);
  await page.locator(".hero-link").click();
  await expect(page).toHaveURL("http://127.0.0.1:8788/");
});
