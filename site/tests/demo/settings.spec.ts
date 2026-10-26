import { expect, test } from "@playwright/test";
import type { FrameLocator, Page } from "@playwright/test";

const openDemo = async (page: Page) => {
  await page.goto("/#browser-demo");

  const frame = page.frameLocator("#browser-demo iframe");

  await expect(frame.locator(".sample-content")).toBeVisible();

  return frame;
};

const menuCommand = async (page: Page, action: string) => {
  const menu = page
    .locator(".mac-menu")
    .filter({ has: page.locator(`[data-action="${action}"]`) });

  await menu.locator(":scope > summary").click();
  await menu.locator(`[data-action="${action}"]`).click();
};

const openSettings = async (
  page: Page,
  frame: FrameLocator,
  section = "General"
) => {
  await menuCommand(page, "settings");
  await expect(frame.locator(".ui-shell-frame")).toBeVisible();
  await frame
    .locator(".section-nav-button")
    .filter({ hasText: section })
    .click();
};

const closeSettings = async (frame: FrameLocator) => {
  await frame.locator(".section-nav-panel .panel-close").click();
  await expect(frame.locator(".ui-shell-frame")).toHaveCount(0);
};

const openSites = async (page: Page, frame: FrameLocator) => {
  await openSettings(page, frame, "Privacy");
  await frame.locator('[data-setting-id="sites"]').getByRole("button").click();
};

test("the full native shortcut catalog records, cancels and updates the Mac-menu hint", async ({
  page,
}) => {
  const frame = await openDemo(page);
  await openSettings(page, frame);
  await frame
    .locator('[data-setting-id="shortcuts"]')
    .getByRole("button")
    .click();

  await Promise.all(
    [
      "Lilo",
      "File",
      "Edit",
      "View",
      "History",
      "Spaces",
      "Tab",
      "Develop",
      "Window",
      "Help",
    ].map((name) =>
      expect(
        frame
          .locator(".ui-shell-frame")
          .getByRole("heading", { exact: true, name })
      ).toBeVisible()
    )
  );

  await expect
    .poll(() => frame.locator(".shortcut-keys").count())
    .toBeGreaterThan(90);

  const newTab = frame
    .locator(".ui-list-row")
    .filter({ has: frame.getByText("New Tab", { exact: true }) });

  const keys = newTab.locator(".shortcut-keys");

  await expect(keys).toHaveText("⌘T");
  await keys.click();
  await expect(keys).toHaveText("Press keys");
  await keys.press("Escape");
  await expect(keys).toHaveText("⌘T");
  await expect(frame.locator(".ui-shell-frame")).toBeVisible();
  await keys.click();
  await keys.press("Meta+Shift+u");
  await expect(keys).toHaveText("⇧⌘U");
  await expect(page.locator('.mac-menu [data-action="newTab"] kbd')).toHaveText(
    "⇧⌘U"
  );
  await closeSettings(frame);
  await frame.locator(".sample-content").press("Meta+Shift+u");
  await expect(frame.locator(".command-bar-input")).toBeVisible();
  await expect(frame.locator(".notice")).toHaveCount(0);
});

test("deleting sample website data stays deleted after closing and reopening Settings", async ({
  page,
}) => {
  const frame = await openDemo(page);
  await openSites(page, frame);
  await frame.getByRole("button", { name: /^notes\.example\.com/u }).click();
  await expect(
    frame.getByRole("heading", { exact: true, name: "notes.example.com" })
  ).toBeVisible();
  await frame
    .getByRole("region", { exact: true, name: "Data" })
    .getByRole("button", { exact: true, name: "Clear" })
    .click();
  await expect(
    frame.getByRole("button", { name: /^notes\.example\.com/u })
  ).toHaveCount(0);
  await closeSettings(frame);
  await openSites(page, frame);
  await expect(
    frame.getByRole("button", { name: /^notes\.example\.com/u })
  ).toHaveCount(0);
  await expect(
    frame.getByRole("button", { name: /^slowtravel\.example\.com/u })
  ).toBeVisible();
  await expect(frame.locator(".notice")).toHaveCount(0);
});

test("default and per-site zoom resize the rendered page and both reset controls work", async ({
  page,
}) => {
  const frame = await openDemo(page);
  await menuCommand(page, "newTab");
  await frame.locator(".command-bar-input").fill("https://example.com/zoom");
  await frame.locator(".command-bar-input").press("Enter");

  const sample = frame.locator(".sample-pane .page");

  const heading = sample.getByRole("heading", {
    exact: true,
    name: "A little space for your internet.",
  });

  await expect(heading).toBeVisible();

  const initialHeight = await heading.evaluate(
    (element) => element.getBoundingClientRect().height
  );

  await openSettings(page, frame, "Appearance");
  await frame
    .getByRole("combobox", { exact: true, name: "Default zoom" })
    .selectOption("1.25");
  await closeSettings(frame);
  await expect(sample).toHaveCSS("zoom", "1.25");
  await expect
    .poll(() =>
      heading.evaluate((element) => element.getBoundingClientRect().height)
    )
    .toBeGreaterThan(initialHeight * 1.2);
  await menuCommand(page, "zoomIn");
  await expect(sample).toHaveCSS("zoom", "1.35");
  await openSites(page, frame);
  await frame.getByRole("button", { name: /^example\.com/u }).click();
  await frame.getByRole("button", { exact: true, name: "Reset" }).click();
  await closeSettings(frame);
  await expect(sample).toHaveCSS("zoom", "1.25");
  await menuCommand(page, "zoomReset");
  await expect(sample).toHaveCSS("zoom", "1");
  await expect(frame.locator(".notice")).toHaveCount(0);
});

test("terminal preferences update the live terminal renderer and survive reopening Settings", async ({
  page,
}) => {
  const frame = await openDemo(page);
  await page.locator(".demo-modes [data-action=terminal]").click();

  const terminal = frame.locator("section.terminal");
  const rows = terminal.locator(".xterm-rows");

  await expect(rows).toBeVisible();
  await expect(rows).toHaveCSS("font-size", "13px");
  await openSettings(page, frame, "Terminal");
  await expect(
    frame.getByRole("combobox", { exact: true, name: "Theme" })
  ).toHaveValue("auto");
  await frame
    .getByRole("combobox", { exact: true, name: "Theme" })
    .selectOption("catppuccin-latte");
  await frame
    .getByRole("combobox", { exact: true, name: "Font" })
    .selectOption("Menlo");
  await frame
    .getByRole("combobox", { exact: true, name: "Size" })
    .selectOption("18");
  await closeSettings(frame);
  await expect(terminal).toHaveCSS("background-color", "rgb(239, 241, 245)");
  await expect(rows).toHaveCSS("color", "rgb(76, 79, 105)");
  await expect(rows).toHaveCSS("font-size", "18px");
  await expect(rows).toHaveCSS("font-family", /Menlo/u);
  await openSettings(page, frame, "Terminal");
  await expect(
    frame.getByRole("combobox", { exact: true, name: "Theme" })
  ).toHaveValue("catppuccin-latte");
  await expect(
    frame.getByRole("combobox", { exact: true, name: "Font" })
  ).toHaveValue("Menlo");
  await expect(
    frame.getByRole("combobox", { exact: true, name: "Size" })
  ).toHaveValue("18");
});

test("replayed onboarding advances through every browsing step and finishes without a Mac-only notice", async ({
  page,
}) => {
  const frame = await openDemo(page);
  await openSettings(page, frame, "Advanced");
  await frame
    .locator('[data-setting-id="replayOnboarding"]')
    .getByRole("button", { exact: true, name: "Replay" })
    .click();
  await frame.getByRole("button", { exact: true, name: "Get started" }).click();

  const card = frame.locator("section.card");

  await expect(card).toHaveAttribute("aria-label", "How will you use Lilo?");
  await card.getByRole("radio", { name: /For browsing/u }).click();
  await card.getByRole("button", { exact: true, name: "Continue" }).click();
  await expect(card).toHaveAttribute("aria-label", "Bring your favorites");
  await card.getByRole("button", { exact: true, name: "Skip" }).click();

  const nextStep = async (title: string) => {
    await expect(card).toHaveAttribute("aria-label", title);
    await card.getByRole("button", { exact: true, name: "Continue" }).click();
  };

  await nextStep("Your passwords");
  await nextStep("Your style");
  await nextStep("Your tabs, your side");
  await nextStep("The essentials");

  await expect(card).toHaveAttribute("aria-label", "3 tips to get started");
  await card.getByRole("button", { exact: true, name: "Let's go" }).click();
  await expect(frame.locator(".toast")).toContainText("Welcome to Lilo.");
  await frame
    .locator(".toast")
    .getByRole("button", { exact: true, name: "Done" })
    .click();
  await expect(card).toHaveCount(0);
  await expect(
    frame.getByRole("dialog", { exact: true, name: "Welcome home." })
  ).toHaveCount(0);
  await expect(frame.locator(".toast")).toHaveCount(0);
  await expect(frame.locator(".notice")).toHaveCount(0);
});
