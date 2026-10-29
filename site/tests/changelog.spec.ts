import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

import { expect, test } from "@playwright/test";

test("MP4 byte ranges support seeking without replacing the player", async ({
  page,
}) => {
  await page.goto("/changelog/#v0.8.0");
  const source = await page.locator("#v0\\.8\\.0 video").getAttribute("src");
  expect(source).toBeTruthy();

  const first = await page.request.get(source ?? "", {
    headers: { Range: "bytes=0-1" },
  });

  expect(first.status()).toBe(206);
  const firstBytes = await first.body();
  expect(firstBytes.length).toBe(2);
  const size = Number(first.headers()["content-range"].split("/").at(-1));
  expect(size).toBeGreaterThan(2);

  const suffix = await page.request.get(source ?? "", {
    headers: { Range: "bytes=-16" },
  });

  expect(suffix.status()).toBe(206);
  const suffixBytes = await suffix.body();
  expect(suffixBytes.length).toBe(16);

  const invalid = await page.request.get(source ?? "", {
    headers: { Range: `bytes=${size}-` },
  });

  expect(invalid.status()).toBe(416);
  expect(invalid.headers()["content-range"]).toBe(`bytes */${size}`);

  const changed = await page.request.get(source ?? "", {
    headers: { "If-Range": '"previous-version"', Range: "bytes=0-1" },
  });

  expect(changed.status()).toBe(200);
  const changedBytes = await changed.body();
  expect(changedBytes.length).toBe(size);
});

for (const language of ["en", "fr"] as const) {
  for (const width of [390, 1280]) {
    test(`0.8.0 shows the native movie and still proof (${language}, ${width})`, async ({
      page,
    }) => {
      await page.setViewportSize({ height: 900, width });
      await page.emulateMedia({ reducedMotion: "reduce" });
      const path = language === "fr" ? "/fr/changelog/" : "/changelog/";
      await page.goto(`${path}#v0.8.0`);
      const release = page.locator("#v0\\.8\\.0");

      await expect(release.locator(".release-recording")).toHaveCount(1);
      await expect(release.locator(".release-image")).toHaveCount(1);
      await expect(release.locator(".release-image button")).toHaveCount(0);
      const still = release.locator(".release-image img");
      await still.scrollIntoViewIfNeeded();
      await expect(still).toHaveJSProperty("complete", true);
      expect(
        await still.evaluate((node) =>
          node instanceof HTMLImageElement
            ? node.naturalWidth >=
              Math.min(
                1600,
                node.getBoundingClientRect().width * devicePixelRatio
              )
            : false
        )
      ).toBe(true);
      expect(
        await page.evaluate(() => document.documentElement.scrollWidth)
      ).toBe(width);

      // oxlint-disable no-await-in-loop -- Each player must be scrolled and operated sequentially.
      for (const player of await release.locator(".release-recording").all()) {
        await player.scrollIntoViewIfNeeded();
        const video = player.locator("video");
        await expect(video).toBeVisible();
        await expect(video).toHaveJSProperty("controls", true);
        await expect(video).toHaveJSProperty("paused", true);
        await video.click();
        await video.evaluate((node) =>
          node instanceof HTMLVideoElement ? node.play() : undefined
        );
        await expect(video).toHaveJSProperty("videoWidth", 1600);
        await expect
          .poll(() =>
            video.evaluate((node) =>
              node instanceof HTMLVideoElement ? node.currentTime : 0
            )
          )
          .toBeGreaterThan(0.1);
        await video.evaluate((node) => {
          if (!(node instanceof HTMLVideoElement)) {
            throw new TypeError("Missing MP4 player");
          }

          const movie = node;
          movie.pause();
          movie.currentTime = 6;
          movie.muted = false;
        });
        await expect(video).toHaveJSProperty("muted", false);
        await expect
          .poll(() =>
            video.evaluate((node) =>
              node instanceof HTMLVideoElement ? node.currentTime : 0
            )
          )
          .toBeGreaterThanOrEqual(6);
        await video.evaluate((node) => {
          if (!(node instanceof HTMLVideoElement)) {
            throw new TypeError("Missing MP4 player");
          }

          const movie = node;
          movie.currentTime = movie.duration - 0.1;

          return movie.play();
        });
        await expect(video).toHaveJSProperty("ended", true);
        await expect(video).toBeVisible();
        await video.evaluate((node) =>
          node instanceof HTMLVideoElement ? node.play() : undefined
        );
        await expect(video).toHaveJSProperty("paused", false);
        await page.locator("h1").scrollIntoViewIfNeeded();
        await expect(video).toHaveJSProperty("paused", true);
      }
      // oxlint-enable no-await-in-loop
    });
  }
}

test("recordings finish and restart their frames on cached replay", async ({
  page,
}) => {
  await page.goto("/changelog/#v0.7.0");
  const player = page.locator("#v0\\.7\\.0 .release-recording");
  const button = player.locator(".recording-toggle");
  const image = player.locator("img:visible");
  await player.scrollIntoViewIfNeeded();
  const poster = await image.getAttribute("src");
  const recording = await image.getAttribute("data-recording");

  if (!recording) {
    throw new Error("Missing animation");
  }

  await page.route(new URL(recording, page.url()).href, (route) =>
    route.fulfill({
      body: readFileSync(
        new URL("../../lilo-ui/e2e/fixtures/playback.webp", import.meta.url)
      ),
      contentType: "image/webp",
    })
  );

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
    const older = page.locator("#v0\\.6\\.0");
    await expect(older.locator(".release-story")).toBeVisible();
    await expect(older.locator(".release-body")).toBeHidden();
    await older.locator("summary").focus();
    await page.keyboard.press("Enter");
    await expect(older.locator(".release-body")).toBeVisible();
    await expect(older.locator(".release-body")).toContainText(
      "Tabs and bookmarks of messaging sites"
    );
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
      const older = page.locator("#v0\\.6\\.0");
      await expect(older.locator(".release-story")).toBeVisible();
      await expect(older.locator(".release-body")).toBeHidden();
      await older.locator("summary").click();
      await expect(older.locator(".release-body")).toBeVisible();
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
