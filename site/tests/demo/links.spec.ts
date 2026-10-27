import { expect, test } from "@playwright/test";
import type { Page } from "@playwright/test";

const openLinks = async (page: Page, french = false) => {
  await page.goto(`${french ? "/fr/" : "/"}#browser-demo`);
  const frame = page.frameLocator("#browser-demo iframe");
  await expect(frame.locator(".repo-top")).toBeVisible();
  await frame.locator(".new-tab-row:visible").click();
  await frame
    .locator(".command-bar-input")
    .fill("https://guide.example.com/links");
  await frame.locator(".command-bar-input").press("Enter");
  await expect(frame.locator(".quick-links")).toBeVisible();

  return frame;
};

test("Shift-click Peeks and Command or middle click adds a background tab without external requests", async ({
  page,
}) => {
  const external: string[] = [];
  page.on("request", (request) => {
    if (
      /^https?:/u.test(request.url()) &&
      new URL(request.url()).hostname !== "127.0.0.1"
    ) {
      external.push(request.url());
    }
  });
  const frame = await openLinks(page);

  const notes = frame.locator(
    '.quick-links a[href="https://notes.example.com"]'
  );

  const source = frame.getByRole("treeitem", {
    exact: true,
    name: "guide.example.com",
  });

  await notes.click({ modifiers: ["Shift"] });
  const peek = frame.getByRole("dialog", { exact: true, name: "Peek" });
  await expect(
    peek.getByRole("textbox", { exact: true, name: "Your notes" })
  ).toBeVisible();
  await expect(source).toHaveAttribute("aria-selected", "true");
  await peek
    .getByRole("button", { exact: true, name: "Close preview" })
    .click();
  const count = await frame.getByRole("treeitem").count();
  await notes.click({ modifiers: ["Meta"] });
  await expect(frame.getByRole("treeitem")).toHaveCount(count + 1);
  await expect(source).toHaveAttribute("aria-selected", "true");
  await notes.click({ button: "middle" });
  await expect(frame.getByRole("treeitem")).toHaveCount(count + 2);
  await expect(source).toHaveAttribute("aria-selected", "true");
  await expect(peek).toHaveCount(0);
  expect(external).toEqual([]);
});

test("link menus support keyboard navigation and work inside Peek and Little windows", async ({
  page,
}) => {
  const frame = await openLinks(page);
  const repo = frame.getByRole("link", { exact: true, name: "Lilo" });
  await repo.press("Shift+F10");
  const menu = frame.getByRole("menu", { exact: true, name: "Link actions" });
  await expect(
    menu.getByRole("menuitem", { exact: true, name: "Peek at Link" })
  ).toBeFocused();
  await page.keyboard.press("ArrowDown");
  await expect(
    menu.getByRole("menuitem", { exact: true, name: "Open Link in New Tab" })
  ).toBeFocused();
  await page.keyboard.press("End");
  await expect(
    menu.getByRole("menuitem", { exact: true, name: "Copy Link" })
  ).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(menu).toBeHidden();
  await expect(repo).toBeFocused();
  await repo.click({ button: "right" });
  await page.keyboard.press("Enter");
  const peek = frame.getByRole("dialog", { exact: true, name: "Peek" });
  await expect(peek.locator(".repo-top")).toBeVisible();
  await peek
    .getByRole("link", { exact: true, name: "↗ getlilo.app" })
    .click({ button: "right" });
  await menu
    .getByRole("menuitem", { exact: true, name: "Open in Little Window" })
    .click();
  await expect(peek).toHaveCount(0);

  const little = frame.getByRole("dialog", {
    exact: true,
    name: "Little window",
  });

  const notes = little.locator(
    '.quick-links a[href="https://notes.example.com"]'
  );

  await notes.click({ button: "right" });
  await menu
    .getByRole("menuitem", { exact: true, name: "Open Link in New Tab" })
    .click();
  await expect(little).toHaveCount(0);
  await expect(
    frame.getByRole("textbox", { exact: true, name: "Your notes" })
  ).toBeVisible();
});

test("right-click can open a background tab and a split while keeping the source page", async ({
  page,
}) => {
  const frame = await openLinks(page);

  const notes = frame.locator(
    '.quick-links a[href="https://notes.example.com"]'
  );

  const menu = frame.getByRole("menu", { exact: true, name: "Link actions" });
  const count = await frame.getByRole("treeitem").count();
  await notes.click({ button: "right" });
  await menu
    .getByRole("menuitem", { exact: true, name: "Open Link in Background Tab" })
    .click();
  await expect(frame.getByRole("treeitem")).toHaveCount(count + 1);
  await expect(
    frame.getByRole("treeitem", { exact: true, name: "guide.example.com" })
  ).toHaveAttribute("aria-selected", "true");
  await notes.click({ button: "right" });
  await menu
    .getByRole("menuitem", { exact: true, name: "Open Link in Split View" })
    .click();
  await expect(frame.locator(".sample-pane")).toHaveCount(2);
  await expect(frame.locator(".quick-links")).toBeVisible();
  await expect(
    frame.getByRole("textbox", { exact: true, name: "Your notes" })
  ).toBeVisible();
});

test("French link actions fit a narrow preview and support keyboard Peek", async ({
  page,
}) => {
  await page.setViewportSize({ height: 844, width: 390 });
  const frame = await openLinks(page, true);

  const notes = frame.locator(
    '.quick-links a[href="https://notes.example.com"]'
  );

  await notes.click({ button: "right" });

  const menu = frame.getByRole("menu", {
    exact: true,
    name: "Actions du lien",
  });

  await expect(menu.getByRole("menuitem")).toHaveCount(6);
  await expect(
    menu.getByRole("menuitem", {
      exact: true,
      name: "Ouvrir le lien en vue partagée",
    })
  ).toBeVisible();

  const bounds = await menu.evaluate((element) => {
    const box = element.getBoundingClientRect();

    return {
      bottom: box.bottom,
      height: innerHeight,
      right: box.right,
      width: innerWidth,
    };
  });

  expect(bounds.right).toBeLessThanOrEqual(bounds.width);
  expect(bounds.bottom).toBeLessThanOrEqual(bounds.height);
  await page.keyboard.press("Escape");
  await notes.press("Shift+Enter");
  await expect(
    frame.getByRole("dialog", { exact: true, name: "Peek" })
  ).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth
    )
  ).toBe(true);
});

test("folder link menus stay open after releasing a right-click", async ({
  page,
}) => {
  await page.goto("/#browser-demo");
  const frame = page.frameLocator("#browser-demo iframe");
  const folder = frame.locator('.file-list a[href$="/tree/main/.changes"]');
  await folder.click({ button: "right" });
  const menu = frame.getByRole("menu", { exact: true, name: "Link actions" });
  await expect(menu).toBeVisible();

  const littleAction = menu.getByRole("menuitem", {
    exact: true,
    name: "Open in Little Window",
  });

  await littleAction.hover();
  await expect(menu).toBeVisible();
  await frame.locator(".repo-top").click();
  await expect(menu).toBeHidden();
  await folder.click({ button: "right" });
  await page.keyboard.press("Escape");
  await expect(menu).toBeHidden();
  await expect(folder).toBeFocused();
  await folder.click({ button: "right" });
  await littleAction.click();

  const little = frame.getByRole("dialog", {
    exact: true,
    name: "Little window",
  });

  await expect(little.locator(".file-content")).toContainText(".changes/");
});

test("repository files and folders support link actions and local navigation history", async ({
  page,
}) => {
  await page.goto("/#browser-demo");
  const frame = page.frameLocator("#browser-demo iframe");
  const readme = frame.locator('.file-list a[href$="/blob/main/README.md"]');
  await readme.click({ modifiers: ["Shift"] });
  const peek = frame.getByRole("dialog", { exact: true, name: "Peek" });
  await expect(peek.locator(".file-content")).toContainText("# Lilo");
  await peek
    .getByRole("button", { exact: true, name: "Close preview" })
    .click();
  const folder = frame.locator('.file-list a[href$="/tree/main/docs"]');
  await folder.click({ button: "right" });
  await frame
    .getByRole("menuitem", { exact: true, name: "Open Link in New Tab" })
    .click();
  await expect(frame.locator(".file-content")).toContainText("docs/");
  await frame.getByRole("link", { exact: true, name: "‹ Files" }).click();
  await expect(frame.locator(".file-list")).toBeVisible();
  await frame.getByRole("button", { exact: true, name: "Go back" }).click();
  await expect(frame.locator(".file-content")).toContainText("docs/");
});
