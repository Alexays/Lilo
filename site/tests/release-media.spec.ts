import { expect, test } from "@playwright/test";

test.use({ channel: "chrome" });

for (const lang of ["en", "fr"]) {
  test(`${lang} film plays on request and names its highlight`, async ({
    page,
  }) => {
    await page.goto(`${lang === "fr" ? "/fr" : ""}/changelog/#v0.8.0`);
    const video = page.locator('[id="v0.8.0-tab-share"] video');
    await video.scrollIntoViewIfNeeded();
    await expect(video).toHaveAccessibleName(
      (await page.locator('[id="v0.8.0-tab-share-title"]').textContent()) ?? ""
    );
    await expect(video).toHaveJSProperty("controls", true);
    await expect(video).toHaveJSProperty("muted", false);
    await expect(video).toHaveJSProperty("paused", true);

    await video.evaluate((v: HTMLVideoElement) => v.play());
    await expect
      .poll(() => video.evaluate((v: HTMLVideoElement) => v.currentTime))
      .toBeGreaterThan(0.2);
  });
}

test("a film pauses once it leaves the screen", async ({ page }) => {
  await page.goto("/changelog/#v0.8.0");
  const video = page.locator('[id="v0.8.0-tab-share"] video');
  await video.scrollIntoViewIfNeeded();
  await video.evaluate((v: HTMLVideoElement) => v.play());
  await expect(video).toHaveJSProperty("paused", false);
  await page.locator("footer").scrollIntoViewIfNeeded();
  await expect(video).toHaveJSProperty("paused", true);
});
