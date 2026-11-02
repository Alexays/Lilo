import { expect, test } from "@playwright/test";

// Continuous trace screenshots distort the video frame budget on software decoders.
test.use({
  channel: "chrome",
  trace: { mode: "retain-on-failure", screenshots: false },
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
      await expect(video).toHaveAttribute("lang", "en");
      const caption = release.locator("figcaption");
      await expect(caption).toBeVisible();
      await expect(caption).toHaveAttribute("lang", lang);

      const description =
        lang === "fr"
          ? "Choisissez du verre, du grain ou de l'uni pour chaque Space."
          : "Choose glass, grain or solid for each Space.";

      const languageLabel =
        lang === "fr"
          ? "Illustration en anglais"
          : "English-language illustration";

      await expect(caption).toContainText(description);
      await expect(caption).toContainText(languageLabel);
      await expect(video).toHaveAccessibleName(
        `${description} ${languageLabel}`
      );
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
      await expect(holiday.locator("img")).toHaveAttribute("lang", "en");
      await expect(holiday.locator("figcaption")).toBeVisible();
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
  }, testInfo) => {
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

    const before = await video.evaluate((v: HTMLVideoElement) => ({
      dropped: v.getVideoPlaybackQuality().droppedVideoFrames,
      frames: v.getVideoPlaybackQuality().totalVideoFrames,
      time: v.currentTime,
    }));

    const started = Date.now();
    await expect
      .poll(() => video.evaluate((v: HTMLVideoElement) => v.currentTime))
      .toBeGreaterThanOrEqual(before.time + 1.5);

    const after = await video.evaluate((v: HTMLVideoElement) => ({
      dropped: v.getVideoPlaybackQuality().droppedVideoFrames,
      frames: v.getVideoPlaybackQuality().totalVideoFrames,
    }));

    const playback = {
      dropped: after.dropped - before.dropped,
      elapsed: (Date.now() - started) / 1000,
      frames: after.frames - before.frames,
    };

    expect(playback.frames).toBeGreaterThanOrEqual(80);
    expect(playback.dropped / playback.frames).toBeLessThan(0.03);
    expect(playback.elapsed).toBeLessThan(2.5);
    await video.evaluate((v: HTMLVideoElement) => v.pause());
    await page.screenshot({ path: testInfo.outputPath("film.png") });
  });
}
