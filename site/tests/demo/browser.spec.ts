import { expect, test } from "@playwright/test";
import type { Page } from "@playwright/test";

const openDemo = async (page: Page, french = false) => {
  await page.goto(`${french ? "/fr/" : "/"}#browser-demo`);
  const demo = page.frameLocator("#browser-demo iframe");
  await expect(
    demo.getByRole("treeitem", { exact: true, name: "Alexays / Lilo, Pinned" })
  ).toBeVisible();
  await expect(demo.locator(".sample-content")).toBeVisible();

  return demo;
};

const menuCommand = async (page: Page, menu: number, action: string) => {
  const item = page.locator(".mac-menu").nth(menu);
  await item.locator(":scope > summary").click();

  if (action === "find") {
    await item.locator("[data-submenu='Find'] > summary").click();
  }

  await item.locator(`[data-action="${action}"]`).click();
};

test("real settings opens from the Mac menu and changes appearance", async ({
  page,
}, info) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const demo = await openDemo(page);
  await expect(demo.locator(".notice")).toHaveCount(0);
  await menuCommand(page, 0, "settings");
  await expect(demo.locator(".ui-shell-frame")).toBeVisible();
  await demo.locator(".section-nav-button", { hasText: "Appearance" }).click();
  await demo.getByRole("radio", { exact: true, name: "Dark" }).click();
  await expect
    .poll(() =>
      demo.locator("html").evaluate((element) => element.style.colorScheme)
    )
    .toBe("dark");
  await demo.getByRole("radio", { exact: true, name: "Light" }).click();
  await expect
    .poll(() =>
      demo.locator("html").evaluate((element) => element.style.colorScheme)
    )
    .toBe("light");
  await page
    .locator("#browser-demo")
    .screenshot({ path: info.outputPath("settings.png") });
  expect(errors).toEqual([]);
});

test("new tabs navigate to local sample pages and closing can be undone", async ({
  page,
}) => {
  const demo = await openDemo(page);
  await menuCommand(page, 1, "newTab");
  await demo.locator(".command-bar-input").fill("notes.example.com");
  await demo.locator(".command-bar-input").press("Enter");
  await expect(demo.getByRole("textbox", { name: "Your notes" })).toBeVisible();
  await menuCommand(page, 1, "closeTab");
  await expect(demo.getByRole("textbox", { name: "Your notes" })).toHaveCount(
    0
  );
  await menuCommand(page, 4, "reopenTab");
  await expect(demo.getByRole("textbox", { name: "Your notes" })).toBeVisible();
});

test("notes remain edited when switching tabs and reset restores the sample world", async ({
  page,
}) => {
  const demo = await openDemo(page);
  await demo
    .getByRole("treeitem", { exact: true, name: "A few good ideas" })
    .click();
  await demo
    .getByRole("textbox", { name: "Your notes" })
    .fill("A note that stays in this demo.");
  await demo
    .getByRole("treeitem", { exact: true, name: "Alexays / Lilo, Pinned" })
    .click();
  await demo
    .getByRole("treeitem", { exact: true, name: "A few good ideas" })
    .click();
  await expect(demo.getByRole("textbox", { name: "Your notes" })).toHaveValue(
    "A note that stays in this demo."
  );
  await page.locator(".demo-tools [data-action='reset']").click();
  await expect(
    demo.getByRole("treeitem", { exact: true, name: "Alexays / Lilo, Pinned" })
  ).toHaveAttribute("aria-selected", "true");
});

test("Spaces and the sample terminal use the real sidebar", async ({
  page,
}) => {
  const demo = await openDemo(page);
  await demo.getByRole("button", { exact: true, name: "Work" }).click();
  await demo
    .getByRole("treeitem", { exact: true, name: "~/Projects/lilo" })
    .click();
  await demo
    .getByRole("textbox", { name: "Terminal command" })
    .fill("echo hello from Lilo");
  await demo.getByRole("textbox", { name: "Terminal command" }).press("Enter");
  await expect(demo.locator(".terminal-output")).toContainText(
    "hello from Lilo"
  );
  await menuCommand(page, 5, "newSpace");
  await demo.locator(".identity-name-input").fill("Research");
  await demo
    .locator(".editor-footer")
    .getByRole("button", { exact: true, name: "Create Space" })
    .click();
  await expect(
    demo.getByRole("button", { exact: true, name: "Research" })
  ).toBeVisible();
});

test("native tab menus are keyboard operable and split views show two pages", async ({
  page,
}) => {
  const demo = await openDemo(page);
  await demo
    .getByRole("treeitem", { exact: true, name: "A few good ideas" })
    .click({ button: "right" });
  await expect(demo.getByRole("menu")).toBeVisible();
  await demo
    .getByRole("menuitem", { exact: true, name: "Bookmark Tab" })
    .press("ArrowDown");
  await expect(
    demo.getByRole("menuitem", { exact: true, name: "Pin Tab" })
  ).toBeFocused();
  await demo
    .getByRole("menuitem", { exact: true, name: "Bookmark Tab" })
    .press("Escape");
  await expect(demo.getByRole("menu")).toHaveCount(0);
  await menuCommand(page, 6, "split");
  await expect(demo.locator(".sample-pane")).toHaveCount(2);
  await demo.locator(".command-bar-input").press("Escape");
  await demo
    .getByRole("button", { exact: true, name: "Close Split View" })
    .click();
  await expect(demo.locator(".sample-pane")).toHaveCount(1);
});

test("French settings and the complete desktop window work on a narrow page", async ({
  page,
}) => {
  await page.setViewportSize({ height: 844, width: 390 });
  await page.goto("/fr/#browser-demo");
  const demo = page.frameLocator("#browser-demo iframe");
  await expect(
    demo.getByRole("treeitem", { exact: true, name: "Alexays / Lilo, Épinglé" })
  ).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth
    )
  ).toBe(true);
  await menuCommand(page, 0, "settings");
  await expect(demo.locator(".ui-shell-frame")).toHaveAttribute(
    "aria-label",
    "Réglages"
  );
  await expect(
    demo.locator(".section-nav-button", { hasText: "Apparence" })
  ).toBeVisible();
});

test("sample content and native-only actions never request an external website", async ({
  page,
}) => {
  const external: string[] = [];
  page.on("request", (request) => {
    if (
      !request.url().startsWith("http://127.0.0.1:8788/") &&
      !request.url().startsWith("data:")
    ) {
      external.push(request.url());
    }
  });
  const demo = await openDemo(page);
  await demo.getByRole("button", { name: "↗ getlilo.app" }).click();
  await expect(
    demo.getByRole("heading", { name: "A little space for your internet." })
  ).toBeVisible();
  expect(page.url()).toBe("http://127.0.0.1:8788/#browser-demo");
  expect(external).toEqual([]);
});

test("the second split pane owns its navigation and leaves the first pane intact", async ({
  page,
}) => {
  const demo = await openDemo(page);
  await demo
    .getByRole("treeitem", { exact: true, name: "A few good ideas" })
    .click();
  await demo
    .getByRole("treeitem", { exact: true, name: "Alexays / Lilo, Pinned" })
    .click({ button: "right" });
  await demo
    .getByRole("menuitem", { exact: true, name: "Open in Split View" })
    .click();
  await expect(
    demo
      .locator(".sample-pane")
      .first()
      .getByRole("textbox", { name: "Your notes" })
  ).toBeVisible();
  await demo
    .locator(".sample-pane")
    .nth(1)
    .getByRole("button", { name: "↗ getlilo.app" })
    .click();
  await expect(
    demo
      .locator(".sample-pane")
      .nth(1)
      .getByRole("heading", { name: "A little space for your internet." })
  ).toBeVisible();
  await expect(
    demo
      .locator(".sample-pane")
      .first()
      .getByRole("textbox", { name: "Your notes" })
  ).toBeVisible();
  await expect(
    demo.getByRole("button", { name: /^Address bar: getlilo\.app\/?$/u })
  ).toBeVisible();
});

test("Find reports missing text and highlights real matches in the sample page", async ({
  page,
}) => {
  const demo = await openDemo(page);
  await menuCommand(page, 2, "find");
  await demo.locator(".find-input").fill("there-is-no-such-phrase-9473");
  await expect(demo.locator(".find-bar")).toContainText("No results");
  await demo.locator(".find-input").fill("Spaces");
  await expect
    .poll(() =>
      demo
        .locator("body")
        .evaluate(() =>
          [...(CSS.highlights.get("demo-find-current") ?? [])]
            .map((range) => range.toString())
            .join("")
        )
    )
    .toBe("Spaces");
  await demo.getByRole("button", { exact: true, name: "Next match" }).click();
  await expect(demo.locator(".notice")).toHaveCount(0);
});

test("diagnostics that require native processes do not start a polling panel", async ({
  page,
}) => {
  const demo = await openDemo(page);
  await demo
    .locator("body")
    .evaluate(() => window.__lilo?.receive({ event: "openProcessManager" }));
  await expect(demo.locator(".notice")).toContainText(
    "Available in the installed Lilo app"
  );
  await expect(
    demo.getByRole("dialog", { exact: true, name: "Process Manager" })
  ).toHaveCount(0);
});

test("Reload resets the current sample page and advertised history shortcuts stay in the demo", async ({
  page,
}) => {
  const demo = await openDemo(page);
  await demo.getByRole("button", { name: /README.md/u }).click();
  await expect(demo.locator(".file-content")).toBeVisible();
  await demo.getByRole("button", { exact: true, name: "Reload" }).click();
  await expect(demo.locator(".file-list")).toBeVisible();
  await demo.locator("body").press("Meta+l");
  await demo.locator(".command-bar-input").fill("https://getlilo.app");
  await demo.locator(".command-bar-input").press("Enter");
  await demo.locator("body").press("Meta+[");
  await expect(
    demo.getByRole("button", {
      exact: true,
      name: "Address bar: github.com/Alexays/Lilo",
    })
  ).toBeVisible();
  await demo.locator("body").press("Meta+]");
  await expect(
    demo.getByRole("button", { name: /^Address bar: getlilo\.app\/?$/u })
  ).toBeVisible();
  expect(page.url()).toBe("http://127.0.0.1:8788/#browser-demo");
});

test.describe("without JavaScript", () => {
  test.use({ javaScriptEnabled: false });

  for (const path of ["/", "/fr/"]) {
    test(`the website remains navigable at ${path}`, async ({ page }) => {
      await page.goto(`${path}#browser-demo`);
      await expect(page.locator("h1")).toBeVisible();
      await expect(page.locator("#browser-demo noscript")).toBeVisible();
      await expect(page.locator("header a[href*='moving']")).toBeVisible();
    });
  }
});

test("fullscreen preserves the interactive settings window", async ({
  page,
}) => {
  const demo = await openDemo(page);
  await page.locator(".demo-tools [data-action='fullscreen']").click();
  await expect
    .poll(() => page.evaluate(() => document.fullscreenElement?.id))
    .toBe("browser-demo");
  await menuCommand(page, 0, "settings");
  await expect(demo.locator(".ui-shell-frame")).toBeVisible();
  await page.locator(".demo-tools [data-action='fullscreen']").click();
  await expect
    .poll(() => page.evaluate(() => document.fullscreenElement))
    .toBeNull();
});

test("resizing the sidebar keeps sample content aligned with the real interface", async ({
  page,
}) => {
  const demo = await openDemo(page);
  const handle = await demo.locator(".sidebar-resize-handle").boundingBox();

  if (!handle) {
    throw new Error("Missing sidebar resize handle");
  }

  const x = handle.x + handle.width / 2;
  const y = handle.y + 100;
  await page.mouse.move(x, y);
  await page.mouse.down();
  await page.mouse.move(x + 220, y, { steps: 4 });
  await page.mouse.up();
  await expect
    .poll(() =>
      demo.locator(".sample-content").evaluate((content) => {
        const chrome = document.querySelector(".content-inset-zone");

        if (!chrome) {
          throw new Error("Missing content inset");
        }

        return Math.abs(
          content.getBoundingClientRect().left -
            chrome.getBoundingClientRect().left
        );
      })
    )
    .toBeLessThan(1);
});

test("the website's explicit appearance survives system appearance changes", async ({
  page,
}) => {
  await page.emulateMedia({ colorScheme: "light" });
  const demo = await openDemo(page);
  await page.locator(".theme-toggle").click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await expect
    .poll(() =>
      demo.locator("html").evaluate((element) => element.style.colorScheme)
    )
    .toBe("dark");
  await page.emulateMedia({ colorScheme: "dark" });
  await page.emulateMedia({ colorScheme: "light" });
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await expect
    .poll(() =>
      demo.locator("html").evaluate((element) => element.style.colorScheme)
    )
    .toBe("dark");
});

test("system appearance propagates through the website to the embedded demo", async ({
  page,
}) => {
  await page.emulateMedia({ colorScheme: "light" });
  const demo = await openDemo(page);
  await expect
    .poll(() =>
      demo.locator("html").evaluate((element) => element.style.colorScheme)
    )
    .toBe("light");
  await page.emulateMedia({ colorScheme: "dark" });
  await expect
    .poll(() =>
      demo.locator("html").evaluate((element) => element.style.colorScheme)
    )
    .toBe("dark");
  await page.emulateMedia({ colorScheme: "light" });
  await expect
    .poll(() =>
      demo.locator("html").evaluate((element) => element.style.colorScheme)
    )
    .toBe("light");
});
