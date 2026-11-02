import { expect, test } from "@playwright/test";
import type { Page } from "@playwright/test";

const menuCommand = async (page: Page, menu: number, action: string) => {
  const item = page.locator("#browser-demo .mac-menu").nth(menu);
  await item.locator(":scope > summary").click();
  await item.locator(`[data-action="${action}"]`).click();
};

for (const french of [false, true]) {
  test(`current tab layouts and address placement keep sample pages clear of the chrome (${french ? "French" : "English"})`, async ({
    page,
  }) => {
    await page.goto(`${french ? "/fr/" : "/"}#browser-demo`);
    const frame = page.frameLocator("#browser-demo iframe");
    await expect(frame.locator(".repo-top")).toBeVisible();
    await menuCommand(page, 0, "settings");
    await frame
      .locator(".section-nav-button", {
        hasText: french ? "Apparence" : "Appearance",
      })
      .click();

    const positions = frame.getByRole("radiogroup", {
      exact: true,
      name: french ? "Onglets" : "Tabs",
    });

    const edges = [
      ["right", french ? "Droite" : "Right"],
      ["top", french ? "Haut" : "Top"],
      ["bottom", french ? "Bas" : "Bottom"],
      ["left", french ? "Gauche" : "Left"],
    ] as const;

    // oxlint-disable no-await-in-loop -- Each edge changes the same window and must settle before the next.
    for (const [edge, label] of edges) {
      await positions.getByRole("radio", { exact: true, name: label }).click();
      await expect(frame.locator("html")).toHaveAttribute(
        "data-tab-position",
        edge
      );
      await expect
        .poll(() =>
          frame.locator(".sample-content").evaluate((element, position) => {
            const content = element.getBoundingClientRect();

            const tabs = document
              .querySelector(
                position === "left" || position === "right"
                  ? ".sidebar"
                  : ".tab-strip-host"
              )
              ?.getBoundingClientRect();

            if (!tabs) {
              return false;
            }

            const clear = {
              bottom: content.bottom <= tabs.top + 1,
              left: content.left >= tabs.right - 1,
              right: content.right <= tabs.left + 1,
              top: content.top >= tabs.bottom - 1,
            }[position];

            return (
              clear &&
              content.width > 300 &&
              content.height > 400 &&
              content.left >= 0 &&
              content.right <= innerWidth &&
              content.bottom <= innerHeight
            );
          }, edge)
        )
        .toBe(true);
    }
    // oxlint-enable no-await-in-loop

    await frame
      .getByRole("radio", {
        exact: true,
        name: french ? "Au-dessus de la page" : "Above the page",
      })
      .click();
    await expect(frame.locator("html")).toHaveAttribute("data-address", "page");
    await expect
      .poll(() =>
        frame.locator(".sample-content").evaluate((element) => {
          const toolbar = document
            .querySelector(".page-toolbar")
            ?.getBoundingClientRect();

          return (
            toolbar !== undefined &&
            element.getBoundingClientRect().top >= toolbar.bottom - 1
          );
        })
      )
      .toBe(true);
    await frame
      .getByRole("radio", {
        exact: true,
        name: french ? "Avec les onglets" : "With the tabs",
      })
      .click();
    await expect(frame.locator("html")).toHaveAttribute("data-address", "tabs");
    await page
      .locator("#browser-demo .demo-modes [data-action=browser]")
      .click();
    await expect(frame.locator(".repo-top")).toBeVisible();
    await expect(frame.locator(".notice")).toHaveCount(0);
  });
}

test("the current saved-tab editor changes the name and home page through the demo host", async ({
  page,
}) => {
  await page.goto("/#browser-demo");
  const frame = page.frameLocator("#browser-demo iframe");
  await frame
    .getByRole("treeitem", { exact: true, name: "Alexays / Lilo, Pinned" })
    .click({ button: "right" });
  await frame.getByRole("menuitem", { exact: true, name: "Edit..." }).click();
  const editor = frame.locator(".saved-tab-editor");
  await expect(editor).toBeVisible();
  await editor.locator(".name-input").fill("Launch notes");
  await editor.locator(".url-input").fill("https://notes.example.com/launch");
  await editor.getByRole("button", { exact: true, name: "Save" }).click();
  await expect(editor).toHaveCount(0);
  await expect(
    frame.getByRole("textbox", { exact: true, name: "Your notes" })
  ).toBeVisible();
  await expect(
    frame.getByRole("treeitem", { exact: true, name: "Launch notes, Pinned" })
  ).toBeVisible();
});

test("Space page colors remain selected after saving and change with the active sample tab", async ({
  page,
}) => {
  await page.goto("/#browser-demo");
  const frame = page.frameLocator("#browser-demo iframe");
  await expect(frame.locator(".repo-top")).toBeVisible();
  await menuCommand(page, 5, "editSpace");
  await frame.getByRole("radio", { exact: true, name: "Page" }).click();
  await frame
    .locator(".editor-panel")
    .getByRole("button", { exact: true, name: "Save" })
    .click();
  await expect(frame.locator(".editor-panel")).toHaveCount(0);

  const background = () =>
    frame
      .locator("html")
      .evaluate((element) => element.style.getPropertyValue("--sidebar-bg"));

  const repoColor = await background();
  await frame
    .getByRole("treeitem", { exact: true, name: "A few good ideas" })
    .click();
  await expect.poll(background).not.toBe(repoColor);
  await menuCommand(page, 5, "editSpace");
  await expect(
    frame.getByRole("radio", { exact: true, name: "Page" })
  ).toHaveAttribute("aria-checked", "true");
  await expect(frame.locator(".notice")).toHaveCount(0);
});
