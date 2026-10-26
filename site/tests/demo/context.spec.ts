import { readFileSync } from "node:fs";

import { expect, test } from "@playwright/test";

for (const locale of ["en", "fr"]) {
  // SAFETY: the repository's native locale namespace maps source phrases to translated strings.
  const catalog = JSON.parse(
    readFileSync(
      new URL(
        `../../../lilo-ui/src/lib/i18n/locales/${locale}.json`,
        import.meta.url
      ),
      "utf-8"
    )
  ).native as Record<string, string>;

  test(`native context labels, submenus, disabled items and focus work in ${locale}`, async ({
    page,
  }) => {
    await page.goto(`/demo/?lang=${locale}`);
    const savedTab = page.locator('[data-tab-id="lilo"]');
    await savedTab.click({ button: "right" });
    const menu = page.locator(".native-menu:not(.context-submenu)");
    await expect(menu.getByRole("menuitem").first()).toHaveText(
      catalog["Edit..."]
    );
    await expect(menu.getByRole("menuitem").first()).toBeFocused();

    const move = menu.getByRole("menuitem", {
      exact: true,
      name: catalog["Move to Space"],
    });

    await move.press("ArrowRight");

    const destinations = page.getByRole("menu", {
      exact: true,
      name: catalog["Move to Space"],
    });

    await expect(destinations.getByRole("menuitem").first()).toBeFocused();
    await destinations.getByRole("menuitem").first().press("ArrowLeft");
    await expect(destinations).toHaveCount(0);
    await expect(move).toBeFocused();

    const newWindow = menu.getByRole("menuitem", {
      name: catalog["Move to New Window"],
    });

    await expect(newWindow).toBeDisabled();
    await expect(newWindow).toContainText(
      locale === "fr" ? "Lilo pour Mac" : "Lilo for Mac"
    );
    await move.press("End");
    await expect(
      menu.getByRole("menuitem", {
        exact: true,
        name: catalog["Close Other Tabs"],
      })
    ).toBeFocused();
    await menu
      .getByRole("menuitem", { exact: true, name: catalog["Close Other Tabs"] })
      .press("ArrowDown");
    await expect(menu.getByRole("menuitem").first()).toBeFocused();
    await menu.getByRole("menuitem").first().press("Escape");
    await expect(menu).toHaveCount(0);
    await expect(savedTab).toBeFocused();
  });
}

test("pinning an inactive tab preserves selection and closing a saved tab offers removal", async ({
  page,
}) => {
  await page.goto("/demo/");
  const active = page.locator('[data-tab-id="lilo"]');
  const notes = page.locator('[data-tab-id="notes"]');
  await notes.click({ button: "right" });
  await page.getByRole("menuitem", { exact: true, name: "Pin Tab" }).click();
  await expect(active).toHaveAttribute("aria-selected", "true");
  await expect(notes).toHaveAttribute("aria-label", "A few good ideas, Pinned");
  await notes.click({ button: "right" });
  await page.getByRole("menuitem", { exact: true, name: "Mute Tab" }).click();
  await notes.click({ button: "right" });
  await expect(
    page.getByRole("menuitem", { exact: true, name: "Unmute Tab" })
  ).toBeVisible();
  await page.getByRole("menuitem", { exact: true, name: "Close Tab" }).click();
  await expect(notes).toBeVisible();
  await notes.click({ button: "right" });
  await page
    .getByRole("menuitem", { exact: true, name: "Remove Pinned Tab" })
    .click();
  await expect(notes).toHaveCount(0);
  await expect(active).toHaveAttribute("aria-selected", "true");
});

test("moving into and out of a folder uses its native pinned section and current destination state", async ({
  page,
}) => {
  await page.goto("/demo/");
  const notes = page.locator('[data-tab-id="notes"]');

  const trips = page.locator(".folder-drop-zone").filter({
    has: page.getByRole("treeitem", { exact: true, name: "Trips" }),
  });

  await notes.click({ button: "right" });
  await page
    .getByRole("menuitem", { exact: true, name: "Move to Folder" })
    .click();
  await page.getByRole("menuitemradio", { exact: true, name: "Trips" }).click();
  await expect(trips.locator('[data-tab-id="notes"]')).toBeVisible();
  await expect(notes).toHaveAttribute("aria-label", "A few good ideas, Pinned");
  await notes.click({ button: "right" });
  await page
    .getByRole("menuitem", { exact: true, name: "Move to Folder" })
    .press("ArrowRight");
  const current = page.getByRole("menuitemradio", { name: "Trips" });
  await expect(current).toHaveAttribute("aria-checked", "true");
  await expect(current).toBeDisabled();
  await page
    .getByRole("menuitem", { exact: true, name: "Remove from Folder" })
    .click();
  await expect(trips.locator('[data-tab-id="notes"]')).toHaveCount(0);
  await expect(notes).toBeVisible();
});

test("creating and deleting a tab folder confirms its content and Cancel preserves it", async ({
  page,
}) => {
  await page.goto("/demo/");
  const notes = page.locator('[data-tab-id="notes"]');
  await notes.click({ button: "right" });
  await page
    .getByRole("menuitem", { exact: true, name: "Create Folder from Tab" })
    .click();

  const folder = page.getByRole("treeitem", {
    exact: true,
    name: "New Folder",
  });

  await expect(folder).toBeVisible();
  await folder.click({ button: "right" });
  await page
    .getByRole("menuitem", { exact: true, name: "Delete Folder" })
    .click();

  const confirmation = page.getByRole("dialog", {
    exact: true,
    name: "Delete New Folder and 1 tab?",
  });

  await expect(confirmation).toBeVisible();
  await expect(
    confirmation.getByRole("button", { exact: true, name: "Cancel" })
  ).toBeFocused();
  await confirmation
    .getByRole("button", { exact: true, name: "Cancel" })
    .click();
  await expect(folder).toBeVisible();
  await expect(notes).toBeVisible();
  await folder.click({ button: "right" });
  await page
    .getByRole("menuitem", { exact: true, name: "Delete Folder" })
    .click();
  await confirmation
    .getByRole("button", { exact: true, name: "Delete" })
    .click();
  await expect(folder).toHaveCount(0);
  await expect(notes).toHaveCount(0);
  await expect(page.locator('[data-tab-id="lilo"]')).toBeVisible();
});

test("extension context actions open the production details page", async ({
  page,
}) => {
  await page.goto("/demo/");
  await page.locator(".extension-icon").first().click({ button: "right" });
  const menu = page.locator(".native-menu");
  await expect(
    menu.getByRole("menuitem", { exact: true, name: "Unpin from Address Bar" })
  ).toBeVisible();
  await menu.getByRole("menuitem", { exact: true, name: "Details" }).click();
  await expect(page.locator(".ui-shell-frame")).toBeVisible();
  await expect(page.locator(".extension-detail")).toContainText("Dark Reader");
});
