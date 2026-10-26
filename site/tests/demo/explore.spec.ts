import { expect, test } from "@playwright/test";
import type { Page } from "@playwright/test";

const openExplore = async (page: Page, french = false) => {
  await page.goto(`${french ? "/fr/" : "/"}#browser-demo`);
  const frame = page.frameLocator("#browser-demo iframe");
  await expect(frame.locator(".sample-content")).toBeVisible();
  await page.locator(".demo-tools [data-action=explore]").click();
  await expect(
    frame.getByRole("dialog", {
      exact: true,
      name: french ? "Découvrir Lilo" : "Explore Lilo",
    })
  ).toBeVisible();

  return frame;
};

test("Explore exposes the shipped capability groups and labels macOS features honestly", async ({
  page,
}) => {
  const frame = await openExplore(page);
  await expect(frame.locator(".feature-list button")).toHaveCount(22);
  await frame.getByRole("button", { name: /^macOS integrations/u }).click();
  await expect(frame.locator(".feature-detail")).toContainText("AppleScript");
  await expect(frame.locator(".platform-note")).toContainText(
    "runs in Lilo for Mac"
  );
  await frame
    .getByRole("searchbox", { exact: true, name: "Find a feature" })
    .fill("HDR");
  await expect(frame.locator(".feature-list button")).toHaveCount(1);
  await expect(frame.locator(".feature-detail h3")).toHaveText(
    "Reading, capture & video"
  );
  await frame
    .getByRole("searchbox", { exact: true, name: "Find a feature" })
    .press("Escape");
  await expect(
    frame.getByRole("dialog", { exact: true, name: "Explore Lilo" })
  ).toHaveCount(0);
});

test("Explore opens real settings and routes into the live agent session", async ({
  page,
}) => {
  const frame = await openExplore(page);
  await frame
    .getByRole("button", { exact: true, name: "Appearance & accessibility" })
    .click();
  await frame.getByRole("button", { exact: true, name: "Try it" }).click();
  await expect(frame.locator(".section-nav-button.active")).toContainText(
    "Appearance"
  );
  await page.locator(".demo-tools [data-action=explore]").click();
  await frame
    .getByRole("button", { exact: true, name: "Agents over MCP" })
    .click();
  await frame.getByRole("button", { exact: true, name: "Try it" }).click();
  await expect(frame.locator(".agent-session .run")).toBeEnabled();
  await expect(frame.locator(".agent-session .run")).toBeVisible();
  await expect(page.locator(".demo-modes [data-action=mcp]")).toHaveAttribute(
    "aria-pressed",
    "true"
  );
});

test("Peek preserves the pinned page and can expand its preview into a tab", async ({
  page,
}) => {
  await page.goto("/#browser-demo");
  const frame = page.frameLocator("#browser-demo iframe");
  await expect(frame.locator(".repo-top")).toBeVisible();
  await frame
    .getByRole("button", { exact: true, name: "↗ getlilo.app" })
    .click();
  const peek = frame.getByRole("dialog", { exact: true, name: "Peek" });
  await expect(peek).toBeVisible();
  await expect(
    peek.getByRole("heading", { name: "A little space for your internet." })
  ).toBeVisible();
  await expect(frame.locator(".repo-top")).toBeVisible();
  await peek.getByRole("button", { exact: true, name: "Open as tab" }).click();
  await expect(peek).toHaveCount(0);
  await expect(
    frame.getByRole("button", { name: /^Address bar: getlilo\.app\/?$/u })
  ).toBeVisible();
  await expect(
    frame.getByRole("treeitem", { exact: true, name: "Alexays / Lilo, Pinned" })
  ).toBeVisible();
});

test("the Little window keeps edited notes when moved into a Space", async ({
  page,
}) => {
  const frame = await openExplore(page);
  await frame
    .getByRole("button", { exact: true, name: "Little window" })
    .click();
  await frame.getByRole("button", { exact: true, name: "Try it" }).click();

  const little = frame.getByRole("dialog", {
    exact: true,
    name: "Little window",
  });

  await little
    .getByRole("textbox", { exact: true, name: "Your notes" })
    .fill("A note from the Little window.");
  await little
    .getByRole("button", { exact: true, name: "Open as tab" })
    .click();
  await expect(little).toHaveCount(0);
  await expect(
    frame.getByRole("textbox", { exact: true, name: "Your notes" })
  ).toHaveValue("A note from the Little window.");
});

test("French Explore fits a touch viewport and switching modes closes its preview", async ({
  page,
}) => {
  await page.setViewportSize({ height: 851, width: 390 });
  const frame = await openExplore(page, true);
  await expect(
    frame.getByRole("searchbox", {
      exact: true,
      name: "Rechercher une fonctionnalité",
    })
  ).toBeFocused();
  await frame
    .getByRole("button", { exact: true, name: "Petite fenêtre" })
    .click();
  await frame.getByRole("button", { exact: true, name: "Essayer" }).click();
  await expect(
    frame.getByRole("dialog", { exact: true, name: "Petite fenêtre" })
  ).toBeVisible();
  await page.locator(".demo-modes [data-action=terminal]").click();
  await expect(frame.locator(".preview-window")).toHaveCount(0);
  await expect(
    frame.getByRole("textbox", { exact: true, name: "Commande du terminal" })
  ).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth
    )
  ).toBe(true);
});
