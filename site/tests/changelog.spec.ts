import { expect, test } from "@playwright/test";

test.use({ channel: "chrome" });

for (const language of ["en", "fr"] as const) {
  const path = language === "fr" ? "/fr/changelog/" : "/changelog/";

  test(`release highlights and full notes work with the keyboard (${language})`, async ({
    page,
  }) => {
    await page.goto(`${path}#v0.7.0`);
    const release = page.locator('[id="v0.7.0"]');
    await expect(release.locator(".release-highlight")).toHaveCount(3);
    const summary = release.locator("summary");
    await summary.focus();
    await page.keyboard.press("Enter");
    await expect(release.locator(".release-body")).toBeVisible();
    await expect(release.locator(".release-body")).toContainText("chrome.mdns");
    await page.keyboard.press("Space");
    await expect(release.locator(".release-body")).toBeHidden();
    await expect(page.locator('[id="v0.14.1"] .release-body')).toBeVisible();
    const demo = release.locator(".recording-action");
    await demo.focus();
    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(
      language === "fr" ? /\/fr\/#browser-demo$/u : /\/#browser-demo$/u
    );
    await expect(page.locator("#browser-demo")).toBeVisible();
  });

  test(`changing appearance preserves the native media and keeps it paused (${language})`, async ({
    page,
  }) => {
    await page.emulateMedia({ colorScheme: "dark" });
    await page.goto(`${path}#v0.7.0`);
    const video = page.locator('[id="v0.7.0"] video');
    await video.scrollIntoViewIfNeeded();
    const poster = await video.getAttribute("poster");
    const source = await video.locator("source").getAttribute("src");
    expect(poster).toBeTruthy();
    expect(source).toBeTruthy();
    await page
      .getByRole("button", {
        exact: true,
        name: language === "fr" ? "Mode sombre" : "Dark mode",
      })
      .click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
    await expect(video).toHaveAttribute("poster", poster ?? "");
    await expect(video.locator("source")).toHaveAttribute("src", source ?? "");
    await expect(video).toHaveJSProperty("paused", true);
    await expect(video).toHaveJSProperty("currentTime", 0);
  });

  test(`release highlights, MP4 controls and stills fit mobile without JavaScript (${language})`, async ({
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
      const release = page.locator('[id="v0.7.0"]');
      await expect(release.locator(".release-highlight")).toHaveCount(3);
      const video = release.locator("video[controls]");
      await video.scrollIntoViewIfNeeded();
      await expect(video).toBeVisible();
      await expect(video).toHaveAttribute("preload", "none");
      await expect(video).toHaveAttribute("poster", /\.png$/u);
      const image = page.locator('[id="v0.6.0"] .release-media img');
      await image.scrollIntoViewIfNeeded();
      await expect(image).toBeVisible();
      await expect(image).toHaveJSProperty("complete", true);
      await expect(image).toHaveJSProperty("naturalWidth", 1920);

      const bounds = await release.evaluate((element) => ({
        pageWidth: document.documentElement.scrollWidth,
        right: element.getBoundingClientRect().right,
        width: innerWidth,
      }));

      expect(bounds.right).toBeLessThanOrEqual(bounds.width);
      expect(bounds.pageWidth).toBe(bounds.width);
      await release.locator("summary").click();
      await expect(release.locator(".release-body")).toBeVisible();
      await expect(page.locator('[id="v0.14.1"] .release-body')).toBeVisible();
      await expect(release.locator(".recording-action")).toHaveAttribute(
        "href",
        `${language === "fr" ? "/fr/" : "/"}#browser-demo`
      );
    } finally {
      await context.close();
    }
  });

  test(`MP4 playback is keyboard controlled under Reduce Motion and stops offscreen (${language})`, async ({
    page,
  }) => {
    const requests: string[] = [];
    page.on("request", (request) => requests.push(request.url()));
    await page.goto(`${path}#v0.7.0`);
    const video = page.locator('[id="v0.7.0"] video');
    await video.scrollIntoViewIfNeeded();
    const source = await video.locator("source").getAttribute("src");
    expect(source).toBeTruthy();
    expect(requests).not.toContain(new URL(source ?? "", page.url()).href);
    await expect(video).toHaveJSProperty("paused", true);
    await expect(video).toHaveJSProperty("autoplay", false);
    await video.focus();
    await page.keyboard.press("Space");
    await expect
      .poll(() => video.evaluate((v: HTMLVideoElement) => v.currentTime))
      .toBeGreaterThan(0.2);
    await expect(video).toHaveJSProperty("muted", false);
    await page.locator("footer").scrollIntoViewIfNeeded();
    await expect(video).toHaveJSProperty("paused", true);
  });

  test(`films stay still until requested with motion allowed (${language})`, async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto(`${path}#v0.7.0`);
    const video = page.locator('[id="v0.7.0"] video');
    await video.scrollIntoViewIfNeeded();
    await expect(video).toHaveJSProperty("autoplay", false);
    await expect(video).toHaveJSProperty("paused", true);
    await expect(video).toHaveJSProperty("currentTime", 0);
  });
}
