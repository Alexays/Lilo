import { expect, test } from "@playwright/test";
import type { Page } from "@playwright/test";
import * as z from "zod/v4";

const open = async (page: Page, mode: "terminal" | "mcp") => {
  await page.goto("/#browser-demo");
  const frame = page.frameLocator("#browser-demo iframe");
  await expect(frame.locator(".sample-content")).toBeVisible();
  await page.locator(`.demo-modes [data-action='${mode}']`).click();

  if (mode === "mcp") {
    await frame.locator(".agent-session details > summary").click();
  }

  return frame;
};

for (const width of [538, 390]) {
  test(`the complete desktop fits a ${width}px preview without the old footer`, async ({
    page,
  }, info) => {
    await page.setViewportSize({ height: 851, width });
    await page.goto("/#browser-demo");
    await expect(
      page.frameLocator("#browser-demo iframe").locator(".sample-content")
    ).toBeVisible();
    await expect(page.locator(".demo-footer")).toHaveCount(0);
    await expect(page.locator(".demo-modes [data-action=mcp]")).toBeVisible();
    await expect
      .poll(async () => {
        const desktop = await page.locator(".demo-desktop").boundingBox();
        const viewport = await page.locator(".demo-viewport").boundingBox();

        if (!desktop || !viewport) {
          return false;
        }

        return (
          desktop.width <= viewport.width + 1 &&
          desktop.height <= viewport.height + 1
        );
      })
      .toBe(true);
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth
      )
    ).toBe(true);
    await page
      .locator("#browser-demo")
      .screenshot({ path: info.outputPath("fitted-demo.png") });
  });
}

test("terminal edits virtual files, updates the browser workspace and survives mode changes", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const frame = await open(page, "terminal");

  const input = frame.getByRole("textbox", {
    exact: true,
    name: "Terminal command",
  });

  await input.fill("printf '# Changed from the terminal\\n' > README.md");
  await input.press("Enter");
  await expect(frame.locator(".workspace-file")).toContainText(
    "Changed from the terminal"
  );
  await input.fill("cat README.md | tr 'a-z' 'A-Z'");
  await input.press("Enter");
  await expect(frame.locator(".terminal-output")).toContainText(
    "CHANGED FROM THE TERMINAL"
  );
  await page.locator(".demo-modes [data-action=browser]").click();
  await expect(
    frame.getByRole("treeitem", { exact: true, name: "Alexays / Lilo, Pinned" })
  ).toBeVisible();
  await page.locator(".demo-modes [data-action=terminal]").click();
  await expect(frame.locator(".workspace-file")).toContainText(
    "Changed from the terminal"
  );
  await expect(frame.locator(".terminal-output")).toContainText(
    "CHANGED FROM THE TERMINAL"
  );
  await input.press("ArrowUp");
  await expect(input).toHaveValue("cat README.md | tr 'a-z' 'A-Z'");
  await page.locator(".demo-tools [data-action=reset]").click();
  await expect(
    frame.getByRole("treeitem", { exact: true, name: "Alexays / Lilo, Pinned" })
  ).toBeVisible();
  await page.locator(".demo-modes [data-action=terminal]").click();
  await expect(frame.locator(".workspace-file")).not.toContainText(
    "Changed from the terminal"
  );
  await input.fill(
    "ln -s missing broken-link; printf '# After the link\\n' > README.md"
  );
  await input.press("Enter");
  await expect(frame.locator(".workspace-file")).toContainText(
    "After the link"
  );
  await frame
    .getByRole("button", { exact: false, name: "broken-link" })
    .click();
  await expect(frame.getByRole("alert")).toBeVisible();
  await expect(
    frame.getByRole("button", { exact: false, name: "README.md" })
  ).toBeVisible();
  await input.fill("printf 'Repaired link' > missing");
  await input.press("Enter");
  await expect(frame.locator(".workspace-file")).toContainText("Repaired link");
  expect(errors).toEqual([]);
});

test("editable MCP calls read actual refs and change the visible sample page", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") {
      errors.push(message.text());
    }
  });
  const frame = await open(page, "mcp");
  const tool = frame.getByRole("combobox", { exact: true, name: "Tool" });
  const args = frame.getByRole("textbox", { exact: true, name: "Arguments" });
  const run = frame.getByRole("button", { exact: false, name: "Run tool" });
  await expect(tool).toBeEnabled();
  await tool.selectOption("navigate");
  await args.fill('{"tabId":1,"url":"https://notes.example.com/agents"}');
  await run.click();
  await expect(
    frame.getByRole("textbox", { exact: true, name: "Your notes" })
  ).toBeVisible();
  await tool.selectOption("read_page");
  await run.click();
  await expect(frame.locator(".mcp-result")).toContainText("Your notes");
  const source = (await frame.locator(".mcp-result").textContent()) ?? "";

  const result = z
    .object({ content: z.array(z.object({ text: z.string() })) })
    .parse(JSON.parse(source));

  const output = result.content.map((item) => item.text).join("\n");

  const ref = output.match(/\[(?<ref>ref_\d+)\] textbox "Your notes"/u)?.groups
    ?.ref;

  if (!ref) {
    throw new Error("read_page did not return the notes field ref");
  }

  await tool.selectOption("form_input");
  await args.fill(
    JSON.stringify({ ref, tabId: 1, value: "A note written through MCP." })
  );
  await run.click();
  await expect(
    frame.getByRole("textbox", { exact: true, name: "Your notes" })
  ).toHaveValue("A note written through MCP.");
  await expect(frame.locator(".mcp-result")).toContainText("Updated");
  await tool.selectOption("navigate");
  await expect(args).toHaveValue(/"url"/u);
  await args.fill('{"tabId":999,"url":"https://notes.example.com"}');
  await run.click();
  await expect(frame.locator(".mcp-result")).toContainText('"isError": true');
  expect(errors).toEqual([]);
});

test("an MCP click navigates its sample tab and keeps the inspector open", async ({
  page,
}) => {
  const frame = await open(page, "mcp");
  const tool = frame.getByRole("combobox", { exact: true, name: "Tool" });
  const args = frame.getByRole("textbox", { exact: true, name: "Arguments" });
  const run = frame.getByRole("button", { exact: false, name: "Run tool" });
  await expect(tool).toBeEnabled();
  await tool.selectOption("navigate");
  await args.fill('{"tabId":1,"url":"https://example.com"}');
  await run.click();
  await expect(frame.locator(".start")).toBeVisible();
  await tool.selectOption("find");
  await args.fill('{"tabId":1,"query":"Lilo"}');
  await run.click();
  await expect(frame.locator(".mcp-result")).toContainText("ref_");
  const source = (await frame.locator(".mcp-result").textContent()) ?? "";

  const result = z
    .object({ content: z.array(z.object({ text: z.string() })) })
    .parse(JSON.parse(source));

  const output = result.content.map((item) => item.text).join("\n");

  const ref = output.match(/\[(?<ref>ref_\d+)\] link "[^"]*Lilo"/u)?.groups
    ?.ref;

  if (!ref) {
    throw new Error("find did not return the Lilo sample link");
  }

  await tool.selectOption("computer");
  await args.fill(JSON.stringify({ action: "left_click", ref, tabId: 1 }));
  await run.click();
  await expect(tool).toBeVisible();
  await expect(frame.locator(".mcp-result")).toContainText("Clicked");
  await expect(frame.locator(".repo-top")).toBeVisible();
});

test("the terminal's MCP command controls the same sample browser without external requests", async ({
  page,
}) => {
  const external: string[] = [];
  page.on("request", (request) => {
    if (
      /^https?:/u.test(request.url()) &&
      !request.url().startsWith("http://127.0.0.1:8788/")
    ) {
      external.push(request.url());
    }
  });
  const frame = await open(page, "terminal");

  const input = frame.getByRole("textbox", {
    exact: true,
    name: "Terminal command",
  });

  await input.fill("mcp list | jq -r '.tools[].name'");
  await input.press("Enter");
  await expect(frame.locator(".terminal-output")).toContainText("form_input");
  await input.fill(
    'mcp call navigate \'{"tabId":1,"url":"https://notes.example.com/agents"}\''
  );
  await input.press("Enter");
  await expect(
    frame.getByRole("textbox", { exact: true, name: "Your notes" })
  ).toBeVisible();
  expect(external).toEqual([]);
});

test("expansion falls back cleanly when native fullscreen is unavailable", async ({
  page,
}) => {
  await page.goto("/#browser-demo");
  await page.evaluate(() => {
    const demo = document.querySelector("#browser-demo");

    if (demo) {
      Object.defineProperty(demo, "requestFullscreen", {
        value: () => Promise.reject(new Error("Fullscreen is unavailable")),
      });
    }
  });
  const expand = page.locator(".demo-tools [data-action=fullscreen]");
  await expand.click();
  await expect(page.locator("#browser-demo")).toHaveAttribute(
    "data-expanded",
    ""
  );
  await expect(page.locator(".site-header")).toHaveJSProperty("inert", true);
  const frame = page.frameLocator("#browser-demo iframe");
  await expect(frame.locator(".sample-content")).toBeVisible();
  await frame.locator("body").press("Escape");
  await expect(page.locator("#browser-demo")).not.toHaveAttribute(
    "data-expanded"
  );
  await expect(page.locator(".site-header")).toHaveJSProperty("inert", false);
  await expect(expand).toBeFocused();
});
