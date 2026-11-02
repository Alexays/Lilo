import { expect, test } from "@playwright/test";

test.use({
  channel: "chrome",
  trace: { mode: "retain-on-failure", screenshots: false },
});

for (const lang of ["en", "fr"]) {
  for (const width of [1280, 390]) {
    test(`${lang} film has localized controls and captions at ${width}px`, async ({
      page,
    }) => {
      await page.setViewportSize({ height: 900, width });
      await page.emulateMedia({
        colorScheme: width === 390 ? "dark" : "light",
        reducedMotion: "reduce",
      });
      await page.goto(`${lang === "fr" ? "/fr" : ""}/changelog/#v0.8.0`);
      const video = page.locator('[id="v0.8.0"] video');
      await video.scrollIntoViewIfNeeded();
      const caption = page.locator('[id="v0.8.0"] figcaption');

      const description =
        lang === "fr"
          ? "Trouvez un onglet et changez celui que vous partagez."
          : "Find a tab and switch what you share.";

      const languageLabel =
        lang === "fr"
          ? "Illustration en anglais"
          : "English-language illustration";

      await expect(caption).toHaveAttribute("lang", lang);
      await expect(caption).toContainText(description);
      await expect(caption).toContainText(languageLabel);
      await expect(video).toHaveAttribute("lang", "en");
      await expect(video).toHaveAccessibleName(
        `${description} ${languageLabel}`
      );
      await expect(video).toHaveJSProperty("controls", true);
      await expect(video).toHaveJSProperty("autoplay", false);
      await expect(video).toHaveJSProperty("muted", false);
      await expect(video).toHaveJSProperty("paused", true);
      await expect(video).toHaveJSProperty("currentTime", 0);
      await video.focus();
      await page.keyboard.press("Space");
      await expect
        .poll(() => video.evaluate((v: HTMLVideoElement) => v.currentTime))
        .toBeGreaterThan(0.2);
      expect(
        await video.evaluate((v: HTMLVideoElement) => [
          v.videoWidth,
          v.videoHeight,
          v.error?.code ?? 0,
        ])
      ).toEqual([1280, 720, 0]);
      await video.evaluate((v: HTMLVideoElement) => {
        v.pause();
        v.currentTime = 5;
      });
      await expect
        .poll(() =>
          video.evaluate(
            (v: HTMLVideoElement) =>
              !v.seeking && Math.abs(v.currentTime - 5) < 0.05
          )
        )
        .toBe(true);
      await video.evaluate((v: HTMLVideoElement) => {
        v.currentTime = v.duration - 0.1;

        return v.play();
      });
      await expect
        .poll(() => video.evaluate((v: HTMLVideoElement) => v.ended))
        .toBe(true);
      await video.evaluate((v: HTMLVideoElement) => v.play());
      await expect(video).toHaveJSProperty("paused", false);
      await page.locator("footer").scrollIntoViewIfNeeded();
      await expect(video).toHaveJSProperty("paused", true);
      await expect(page.locator('[id="v0.14.1"] .release-media')).toHaveCount(
        0
      );
      expect(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth
        )
      ).toBe(true);
    });
  }

  test(`${lang} film stays available without JavaScript`, async ({
    browser,
  }) => {
    const context = await browser.newContext({
      javaScriptEnabled: false,
      viewport: { height: 844, width: 390 },
    });

    try {
      const page = await context.newPage();
      await page.goto(`${lang === "fr" ? "/fr" : ""}/changelog/#v0.8.0`);
      const video = page.locator('[id="v0.8.0"] video[controls]');
      await video.scrollIntoViewIfNeeded();
      await expect(video).toBeVisible();
      await expect(video).toHaveAttribute("preload", "none");
      await expect(video).toHaveAttribute(
        "poster",
        "/release-media/0.8.0/tab-share.png"
      );
      await expect(page.locator('[id="v0.8.0"] figcaption')).toBeVisible();
      await page.locator('[id="v0.8.0"] summary').click();
      await expect(page.locator('[id="v0.8.0"] .release-body')).toBeVisible();
    } finally {
      await context.close();
    }
  });
}
