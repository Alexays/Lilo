import { expect, test } from "@playwright/test";

for (const french of [false, true]) {
  test(`native menu groups, alternate commands and Mac availability (${french ? "French" : "English"})`, async ({
    page,
  }) => {
    await page.goto(`${french ? "/fr/" : "/"}#browser-demo`);
    const frame = page.frameLocator("#browser-demo iframe");
    await expect(frame.locator(".repo-top")).toBeVisible();

    await expect(page.locator(".mac-menu > summary")).toHaveText(
      french
        ? [
            "Lilo",
            "Fichier",
            "Édition",
            "Présentation",
            "Historique",
            "Espaces",
            "Onglet",
            "Développement",
            "Fenêtre",
            "Aide",
          ]
        : [
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
          ]
    );

    const file = page.locator(".mac-menu[data-menu='File']");
    await file.locator(":scope > summary").click();
    await expect(file.locator("[data-action='newTab']")).toBeEnabled();
    await expect(
      file.locator("[data-action='newTerminal'] .menu-label")
    ).toHaveText(french ? "Nouvel onglet terminal" : "New Terminal Tab");
    await expect(file.locator("[data-action='newTerminal'] kbd")).toHaveText(
      "⌃`"
    );
    await expect(file.locator("[data-action='closeTab']")).toBeVisible();
    await expect(file.locator("[data-action='closeOtherTabs']")).toBeHidden();
    await page.keyboard.down("Alt");
    await expect(file.locator("[data-action='closeTab']")).toBeHidden();
    await expect(file.locator("[data-action='closeOtherTabs']")).toBeVisible();
    await page.keyboard.up("Alt");
    await expect(file.locator("[data-action='closeTab']")).toBeVisible();

    const nativeOnly = file.locator("[data-native-only]").first();
    await expect(nativeOnly).toBeDisabled();
    await expect(nativeOnly).toHaveAttribute("title", /Mac/u);
    await expect(page.locator(".mac-menu [data-action='reset']")).toHaveCount(
      0
    );
    await expect(page.locator(".mac-menu [data-action='explore']")).toHaveCount(
      0
    );

    await file.locator(":scope > summary").press("Escape");
    const view = page.locator(".mac-menu[data-menu='View']");
    await view.locator(":scope > summary").click();
    await expect(view.locator("[data-action='sidebar'] kbd")).toHaveText("⇧⌘S");
    await expect(view.locator("[data-action='reloadFromOrigin']")).toBeHidden();
    await page.keyboard.down("Shift");
    await expect(view.locator("[data-action='reload']")).toBeHidden();
    await expect(
      view.locator("[data-action='reloadFromOrigin']")
    ).toBeVisible();
    await page.keyboard.up("Shift");
    await expect(view.locator("[data-action='reload']")).toBeVisible();
  });
}

test("application menus support arrows, nested menus, Escape and outside clicks", async ({
  page,
}) => {
  await page.goto("/#browser-demo");
  const frame = page.frameLocator("#browser-demo iframe");
  await expect(frame.locator(".repo-top")).toBeVisible();

  const file = page.locator(".mac-menu[data-menu='File']");
  await file.locator(":scope > summary").focus();
  await page.keyboard.press("ArrowDown");
  await expect(file.locator("[data-action='newTab']")).toBeFocused();
  await page.keyboard.press("ArrowRight");

  const edit = page.locator(".mac-menu[data-menu='Edit']");

  const firstEditAction = edit
    .locator(":scope > .menu-items > button:enabled:visible")
    .first();

  await expect(edit).toHaveAttribute("open");
  await expect(firstEditAction).toBeFocused();
  await expect(file).not.toHaveAttribute("open");

  const find = edit.locator("[data-submenu='Find']");
  await find.locator("summary").focus();
  await page.keyboard.press("ArrowRight");
  await expect(find.locator("[data-action='find']")).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(find).not.toHaveAttribute("open");
  await expect(find.locator("summary")).toBeFocused();
  await expect(edit).toHaveAttribute("open");
  await page.keyboard.press("Escape");
  await expect(edit).not.toHaveAttribute("open");
  await expect(edit.locator(":scope > summary")).toBeFocused();

  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("End");
  await expect(edit.locator("[data-submenu='Speech'] > summary")).toBeFocused();
  await page.keyboard.press("Home");
  await expect(firstEditAction).toBeFocused();
  await page.locator(".demo-modes [data-action='browser']").click();
  await expect(page.locator(".mac-menu[open]")).toHaveCount(0);
});

test("menu labels, checked Spaces and history availability follow the same demo state", async ({
  page,
}) => {
  await page.goto("/#browser-demo");
  const frame = page.frameLocator("#browser-demo iframe");
  await expect(frame.locator(".repo-top")).toBeVisible();

  const history = page.locator(".mac-menu[data-menu='History']");
  await history.locator(":scope > summary").click();
  await expect(history.locator("[data-action='back']")).toBeDisabled();
  await expect(history.locator("[data-action='reopenTab']")).toBeDisabled();
  await history.locator(":scope > summary").press("Escape");

  const tab = page.locator(".mac-menu[data-menu='Tab']");
  await tab.locator(":scope > summary").click();
  await expect(tab.locator("[data-action='pin'] .menu-label")).toHaveText(
    "Unpin Tab"
  );
  await tab.locator("[data-action='pin']").click();
  await tab.locator(":scope > summary").click();
  await expect(tab.locator("[data-action='pin'] .menu-label")).toHaveText(
    "Pin Tab"
  );
  await tab.locator(":scope > summary").press("Escape");

  const spaces = page.locator(".mac-menu[data-menu='Spaces']");
  await spaces.locator(":scope > summary").click();
  await expect(spaces.locator("[data-id='home']")).toHaveAttribute(
    "aria-checked",
    "true"
  );
  await spaces.locator("[data-id='work']").click();
  await expect(
    frame.getByRole("treeitem", { exact: true, name: "~/Projects/lilo" })
  ).toBeVisible();
  await spaces.locator(":scope > summary").click();
  await expect(spaces.locator("[data-id='work']")).toHaveAttribute(
    "aria-checked",
    "true"
  );
  await expect(spaces.locator("[data-id='home']")).toHaveAttribute(
    "aria-checked",
    "false"
  );
});

test("menus follow language changes in the real Settings screen", async ({
  page,
}) => {
  await page.goto("/#browser-demo");
  const frame = page.frameLocator("#browser-demo iframe");
  await expect(frame.locator(".repo-top")).toBeVisible();
  const app = page.locator(".mac-menu[data-menu='Lilo']");
  await app.locator(":scope > summary").click();
  await app.locator("[data-action='settings']").click();
  await frame
    .getByRole("combobox", { exact: true, name: "Language" })
    .selectOption("fr");
  await expect(page.locator("[data-menu='File'] > summary")).toHaveText(
    "Fichier"
  );
  await expect(
    page.locator("[data-action='selectTab1'] .menu-label")
  ).toHaveText("Onglet 1");
  await expect(page.locator("[data-action='pin'] .menu-label")).toHaveText(
    "Désépingler l'onglet"
  );
  await expect(
    page.locator("[data-menu-list='recentlyClosed'] button")
  ).toHaveText("Aucun onglet fermé");
  await frame
    .getByRole("combobox", { exact: true, name: "Langue" })
    .selectOption("en");
  await expect(page.locator("[data-menu='File'] > summary")).toHaveText("File");
  await expect(page.locator("[data-action='pin'] .menu-label")).toHaveText(
    "Unpin Tab"
  );
});
