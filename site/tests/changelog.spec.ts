import { createHash } from "node:crypto";

import { expect, test } from "@playwright/test";

test("0.8.0 shares the approved native feature recordings", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/changelog/#v0.8.0");
  const release = page.locator("#v0\\.8\\.0");
  await expect(release.locator(".release-recording")).toHaveCount(2);

  // oxlint-disable no-await-in-loop -- Each player must be scrolled and operated sequentially.
  for (const player of await release.locator(".release-recording").all()) {
    await player.scrollIntoViewIfNeeded();
    await expect(player.locator("img:visible")).toHaveJSProperty(
      "complete",
      true
    );
    await expect(player.locator(".recording-toggle")).toHaveAttribute(
      "aria-pressed",
      "false"
    );
    await player.locator(".recording-toggle").click();
    await expect(player.locator(".recording-toggle")).toHaveAttribute(
      "aria-pressed",
      "true"
    );
    await player.locator(".recording-toggle").click();
  }
  // oxlint-enable no-await-in-loop
});

test("recordings finish and restart their frames on cached replay", async ({
  page,
}) => {
  await page.goto("/changelog/#v0.7.0");
  const player = page.locator("#v0\\.7\\.0 .release-recording");
  const button = player.locator(".recording-toggle");
  const image = player.locator("img:visible");
  await player.scrollIntoViewIfNeeded();
  const poster = await image.getAttribute("src");

  const pixels = async () =>
    createHash("sha256")
      .update(await image.screenshot())
      .digest("hex");

  await button.click();
  await expect(image).toHaveJSProperty("complete", true);
  const firstFrame = await pixels();
  await expect.poll(pixels, { timeout: 3000 }).not.toBe(firstFrame);
  await expect(button).toHaveAttribute("aria-pressed", "false", {
    timeout: 8000,
  });
  await expect(image).toHaveJSProperty(
    "src",
    new URL(poster ?? "", page.url()).href
  );
  await button.click();
  await expect.poll(pixels, { timeout: 700 }).toBe(firstFrame);
  await expect.poll(pixels, { timeout: 3000 }).not.toBe(firstFrame);
  await button.click();
});

for (const language of ["en", "fr"] as const) {
  const path = language === "fr" ? "/fr/changelog/" : "/changelog/";

  test(`release highlights and full notes work with the keyboard (${language})`, async ({
    page,
  }) => {
    await page.goto(`${path}#v0.7.0`);
    const release = page.locator("#v0\\.7\\.0");
    await expect(release.locator(".release-highlight")).toHaveCount(3);
    const summary = release.locator("summary");
    await summary.focus();
    await page.keyboard.press("Enter");
    await expect(release.locator(".release-body")).toBeVisible();
    await expect(release.locator(".release-body")).toContainText("chrome.mdns");
    await page.keyboard.press("Space");
    await expect(release.locator(".release-body")).toBeHidden();
    await expect(page.locator("#v0\\.6\\.0 .release-body")).toBeVisible();
    const demo = release.locator(".recording-action");
    await demo.focus();
    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(
      language === "fr" ? /\/fr\/#browser-demo$/u : /\/#browser-demo$/u
    );
    await expect(page.locator("#browser-demo")).toBeVisible();
  });

  test(`release captures follow the chosen appearance (${language})`, async ({
    page,
  }) => {
    await page.emulateMedia({ colorScheme: "dark" });
    await page.goto(`${path}#v0.7.0`);
    const capture = page.locator("#v0\\.7\\.0 .capture");
    await capture.scrollIntoViewIfNeeded();
    await expect(capture.locator(".capture-dark")).toBeVisible();
    await expect(capture.locator(".capture-light")).toBeHidden();
    await page
      .getByRole("button", {
        exact: true,
        name: language === "fr" ? "Mode sombre" : "Dark mode",
      })
      .click();
    await expect(capture.locator(".capture-light")).toBeVisible();
    await expect(capture.locator(".capture-dark")).toBeHidden();
  });

  test(`release highlights fit mobile and work without JavaScript (${language})`, async ({
    browser,
  }) => {
    const context = await browser.newContext({
      colorScheme: "dark",
      javaScriptEnabled: false,
      viewport: { height: 844, width: 390 },
    });

    try {
      const page = await context.newPage();
      await page.goto(`${path}#v0.7.0`);
      const release = page.locator("#v0\\.7\\.0");
      await expect(release.locator(".release-highlight")).toHaveCount(3);
      await expect(release.locator(".recording-toggle")).toBeHidden();
      const image = release.locator(".capture-dark");
      await image.scrollIntoViewIfNeeded();
      await expect(image).toBeVisible();
      await expect(image).toHaveJSProperty("complete", true);
      expect(
        await image.evaluate((element) =>
          element instanceof HTMLImageElement ? element.naturalWidth : 0
        )
      ).toBeGreaterThan(0);

      const bounds = await release.evaluate((element) => ({
        pageWidth: document.documentElement.scrollWidth,
        right: element.getBoundingClientRect().right,
        width: innerWidth,
      }));

      expect(bounds.right).toBeLessThanOrEqual(bounds.width);
      expect(bounds.pageWidth).toBe(bounds.width);
      await release.locator("summary").click();
      await expect(release.locator(".release-body")).toBeVisible();
      await expect(page.locator("#v0\\.6\\.0 .release-body")).toBeVisible();
      await expect(release.locator(".recording-action")).toHaveAttribute(
        "href",
        `${language === "fr" ? "/fr/" : "/"}#browser-demo`
      );
    } finally {
      await context.close();
    }
  });

  test(`recordings respect Reduce Motion and stop outside the viewport (${language})`, async ({
    page,
  }) => {
    const requests: string[] = [];
    page.on("request", (request) => requests.push(request.url()));
    await page.goto(`${path}#v0.7.0`);
    const player = page.locator("#v0\\.7\\.0 .release-recording");
    await player.scrollIntoViewIfNeeded();
    const button = player.locator(".recording-toggle");
    const image = player.locator("img:visible");
    const animation = await image.getAttribute("data-recording");
    const poster = await image.getAttribute("src");
    expect(animation).toBeTruthy();
    expect(poster).toBeTruthy();
    await expect(button).toHaveAttribute("aria-pressed", "false");
    await expect(button).toHaveAccessibleName(
      language === "fr" ? "Lire l'animation" : "Play walkthrough"
    );
    expect(requests).not.toContain(new URL(animation ?? "", page.url()).href);
    await button.focus();
    await page.keyboard.press("Enter");
    await expect(button).toHaveAttribute("aria-pressed", "true");
    await expect(button).toHaveAccessibleName(
      language === "fr" ? "Arrêter" : "Stop"
    );
    await expect(image).toHaveAttribute("src", animation ?? "");
    await button.click();
    await expect(button).toHaveAttribute("aria-pressed", "false");
    await expect(image).toHaveJSProperty(
      "src",
      new URL(poster ?? "", page.url()).href
    );
    await button.click();
    await expect(button).toHaveAttribute("aria-pressed", "true");
    await page.evaluate(() => scrollTo(0, document.body.scrollHeight));
    await expect(button).toHaveAttribute("aria-pressed", "false");
    await expect(image).toHaveJSProperty(
      "src",
      new URL(poster ?? "", page.url()).href
    );
  });

  test(`recordings play once in view and stop when the appearance changes (${language})`, async ({
    page,
  }) => {
    await page.emulateMedia({
      colorScheme: "dark",
      reducedMotion: "no-preference",
    });
    await page.goto(`${path}#v0.7.0`);
    const player = page.locator("#v0\\.7\\.0 .release-recording");
    const button = player.locator(".recording-toggle");
    await player.scrollIntoViewIfNeeded();
    await expect(button).toHaveAttribute("aria-pressed", "true");
    await page
      .getByRole("button", {
        exact: true,
        name: language === "fr" ? "Mode sombre" : "Dark mode",
      })
      .click();
    await expect(button).toHaveAttribute("aria-pressed", "false");
    await expect(player.locator(".capture-light")).toBeVisible();
    await player.scrollIntoViewIfNeeded();
    await page.evaluate(async () => {
      const settled = Promise.withResolvers<undefined>();
      requestAnimationFrame(() => {
        requestAnimationFrame(() => settled.resolve(undefined));
      });
      await settled.promise;
    });
    await expect(button).toHaveAttribute("aria-pressed", "false");
  });
}
