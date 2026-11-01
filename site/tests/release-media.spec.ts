import { expect, test } from "@playwright/test";

test.use({ channel: "chrome" });

test("the deployed media route supports bounded byte ranges and invalid ranges", async ({
  request,
}) => {
  const url = "/release-media/0.11.0/spaces.mp4";
  const partial = await request.get(url, { headers: { Range: "bytes=0-1" } });
  expect(partial.status()).toBe(206);
  expect(partial.headers()["content-range"]).toMatch(/^bytes 0-1\/\d+$/u);
  const partialBody = await partial.body();
  expect(partialBody.length).toBe(2);
  const suffix = await request.get(url, { headers: { Range: "bytes=-16" } });
  expect(suffix.status()).toBe(206);
  const suffixBody = await suffix.body();
  expect(suffixBody.length).toBe(16);

  const invalid = await request.get(url, {
    headers: { Range: "bytes=999999999-" },
  });

  expect(invalid.status()).toBe(416);
});

for (const lang of ["en", "fr"]) {
  for (const width of [1280, 390]) {
    test(`${lang} release media plays with sound at ${width}px and stays still until requested`, async ({
      page,
    }, testInfo) => {
      await page.setViewportSize({ height: 900, width });
      await page.emulateMedia({
        colorScheme: width === 390 ? "dark" : "light",
      });
      await page.goto(`${lang === "fr" ? "/fr" : ""}/changelog/#v0.11.0`);
      const release = page.locator('[id="v0.11.0"]');
      const video = release.locator("video");
      await expect(video).toBeVisible();
      expect(
        await video.evaluate((v: HTMLVideoElement) => ({
          controls: v.controls,
          muted: v.muted,
          paused: v.paused,
          time: v.currentTime,
        }))
      ).toEqual({ controls: true, muted: false, paused: true, time: 0 });
      await video.evaluate((v: HTMLVideoElement) => v.play());
      await expect
        .poll(() => video.evaluate((v: HTMLVideoElement) => v.currentTime))
        .toBeGreaterThan(0.2);
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
      await page.screenshot({ path: testInfo.outputPath("spaces.png") });
      await video.evaluate((v: HTMLVideoElement) => {
        v.currentTime = v.duration - 0.1;

        return v.play();
      });
      await expect
        .poll(() => video.evaluate((v: HTMLVideoElement) => v.ended))
        .toBe(true);
      await video.evaluate((v: HTMLVideoElement) => v.play());
      await expect
        .poll(() =>
          video.evaluate(
            (v: HTMLVideoElement) => !v.paused && v.currentTime < 3
          )
        )
        .toBe(true);
      await page.locator('[id="v0.13.0"]').scrollIntoViewIfNeeded();
      await expect
        .poll(() => video.evaluate((v: HTMLVideoElement) => v.paused))
        .toBe(true);
      const holiday = page.locator('[id="v0.13.0"] .release-media');
      await expect(holiday.locator("video")).toHaveCount(0);
      await expect(holiday.locator("img")).toBeVisible();
      expect(
        await holiday
          .locator("img")
          .evaluate((i: HTMLImageElement) => i.naturalWidth)
      ).toBe(1920);
      await page.screenshot({ path: testInfo.outputPath("holiday-icons.png") });
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
}

for (const version of [
  "0.14.0",
  "0.11.0",
  "0.10.0",
  "0.9.0",
  "0.8.0",
  "0.7.0",
  "0.2.0",
  "0.1.3",
]) {
  test(`the ${version} film decodes its actual native footage`, async ({
    page,
  }) => {
    await page.goto(`/changelog/#v${version}`);
    const video = page.locator(`[id="v${version}"] video`);
    await video.scrollIntoViewIfNeeded();
    await video.evaluate((v: HTMLVideoElement) => v.play());
    await expect
      .poll(() => video.evaluate((v: HTMLVideoElement) => v.currentTime))
      .toBeGreaterThan(0.1);
    expect(
      await video.evaluate((v: HTMLVideoElement) => [
        v.videoWidth,
        v.videoHeight,
        v.error?.code ?? 0,
      ])
    ).toEqual([1920, 1080, 0]);
    await video.evaluate((v: HTMLVideoElement) => v.pause());
  });
}

test("native MP4 controls and stills work without JavaScript", async ({
  browser,
}) => {
  const context = await browser.newContext({ javaScriptEnabled: false });
  const page = await context.newPage();
  await page.goto("/fr/changelog/#v0.11.0");
  await expect(page.locator('[id="v0.11.0"] video[controls]')).toBeVisible();
  await page.locator('[id="v0.13.0"]').scrollIntoViewIfNeeded();
  await expect(page.locator('[id="v0.13.0"] img')).toBeVisible();
  await context.close();
});
