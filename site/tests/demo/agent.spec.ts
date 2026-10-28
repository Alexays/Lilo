import { expect, test } from "@playwright/test";
import type { Page } from "@playwright/test";
import * as z from "zod/v4";

const openAgent = async (page: Page, french = false) => {
  await page.goto(`${french ? "/fr/" : "/"}#browser-demo`);
  const frame = page.frameLocator("#browser-demo iframe");
  await expect(frame.locator(".sample-content")).toBeVisible();
  await page.locator("#browser-demo .demo-modes [data-action=mcp]").click();
  await expect(frame.locator(".agent-session .run")).toBeEnabled();
  await expect(frame.locator(".launch-page")).toBeVisible();

  return frame;
};

test("manual tools can stop an approval and cancel it when the inspector closes", async ({
  page,
}) => {
  const frame = await openAgent(page);
  await frame.locator(".agent-session .run").click();
  await frame
    .getByRole("button", { exact: true, name: "Deny" })
    .click({ timeout: 15_000 });
  await expect(frame.locator(".agent-session")).toHaveAttribute(
    "data-agent-status",
    "denied"
  );
  await frame.locator(".agent-session details > summary").click();
  const tool = frame.getByRole("combobox", { exact: true, name: "Tool" });
  const args = frame.getByRole("textbox", { exact: true, name: "Arguments" });
  const run = frame.getByRole("button", { exact: false, name: "Run tool" });
  await expect(tool).toBeEnabled();
  await tool.selectOption("find");
  await args.fill('{"tabId":1,"query":"Publish update"}');
  await run.click();
  await expect(frame.locator(".mcp-result")).toContainText("ref_");

  const result = z
    .object({ content: z.array(z.object({ text: z.string() })) })
    .parse(
      JSON.parse((await frame.locator(".mcp-result").textContent()) ?? "")
    );

  const ref = result.content
    .map((item) => item.text)
    .join("\n")
    .match(/\[(?<ref>ref_\d+)\] button /u)?.groups?.ref;

  expect(ref).toBeTruthy();
  await tool.selectOption("computer");
  await args.fill(JSON.stringify({ action: "left_click", ref, tabId: 1 }));
  await run.click();
  await expect(
    frame.getByRole("button", { exact: true, name: "Allow Once" })
  ).toBeVisible();
  await frame.locator(".mcp-actions .stop").click();
  await expect(
    frame.getByRole("button", { exact: true, name: "Allow Once" })
  ).toHaveCount(0);
  await expect(run).toBeEnabled();
  await run.click();
  await expect(
    frame.getByRole("button", { exact: true, name: "Allow Once" })
  ).toBeVisible();
  await page.locator("#browser-demo .demo-modes [data-action=browser]").click();
  await expect(
    frame.getByRole("button", { exact: true, name: "Allow Once" })
  ).toHaveCount(0);
  await page.locator("#browser-demo .demo-modes [data-action=mcp]").click();
  await expect(frame.locator(".published")).toBeEmpty();
});

test("the real Agents setting disables both the Codex session and manual tools", async ({
  page,
}) => {
  const frame = await openAgent(page);
  const menu = page.locator("#browser-demo .mac-menu").first();
  await menu.locator(":scope > summary").click();
  await menu.locator('[data-action="settings"]').click();
  await frame.locator(".section-nav-button", { hasText: "AI agents" }).click();
  await frame
    .getByRole("checkbox", { exact: true, name: "Let AI agents use Lilo" })
    .press("Space");
  await page.locator("#browser-demo .demo-modes [data-action=mcp]").click();
  await expect(frame.locator(".agent-session .run")).toBeDisabled();
  await expect(frame.locator(".agent-session .connection")).toContainText(
    "Agent access is off"
  );
  await frame.locator(".agent-session details > summary").click();
  await expect(
    frame.getByRole("button", { exact: false, name: "Run tool" })
  ).toBeDisabled();
  await menu.locator(":scope > summary").click();
  await menu.locator('[data-action="settings"]').click();
  await frame.locator(".section-nav-button", { hasText: "AI agents" }).click();
  await frame
    .getByRole("checkbox", { exact: true, name: "Let AI agents use Lilo" })
    .press("Space");
  await page.locator("#browser-demo .demo-modes [data-action=mcp]").click();
  await expect(frame.locator(".agent-session .run")).toBeEnabled();
});

test("Codex reads the current checklist, clicks and types, and waits for native approval before publishing", async ({
  page,
}, info) => {
  const errors: string[] = [];
  const external: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("request", (request) => {
    if (
      /^https?:/u.test(request.url()) &&
      !request.url().startsWith("http://127.0.0.1:8788/")
    ) {
      external.push(request.url());
    }
  });
  await page.emulateMedia({ reducedMotion: "no-preference" });
  const frame = await openAgent(page);
  await expect(
    frame.getByRole("combobox", { exact: true, name: "Tool" })
  ).toHaveCount(0);
  await frame
    .getByRole("checkbox", { exact: true, name: "Copy reviewed" })
    .check();
  await frame
    .getByRole("button", { exact: false, name: "Run with Codex" })
    .click();
  await expect(frame.locator(".agent-cursor")).toBeVisible();
  await expect(frame.locator(".agent-frame")).toContainText(
    "Codex controls this tab"
  );
  await expect(
    frame.getByRole("button", { exact: true, name: "Allow Once" })
  ).toBeVisible({ timeout: 15_000 });
  await expect(
    frame.getByRole("checkbox", { exact: true, name: "Settings verified" })
  ).toBeChecked();
  await expect(
    frame.getByRole("textbox", { exact: true, name: "Project update" })
  ).toHaveValue(
    "All three launch checks are complete. Ready for the next release."
  );
  await expect(frame.locator(".agent-steps")).not.toContainText(
    "Complete: Copy reviewed"
  );
  await expect(frame.locator(".published")).toBeEmpty();
  await page
    .locator("#browser-demo")
    .screenshot({ path: info.outputPath("agent-approval.png") });
  await frame.getByRole("button", { exact: true, name: "Allow Once" }).click();
  await expect(frame.locator(".agent-session")).toHaveAttribute(
    "data-agent-status",
    "done"
  );
  await expect(frame.locator(".published")).toContainText("Update published");
  await expect(frame.locator(".agent-frame")).toHaveCount(0);
  expect(errors).toEqual([]);
  expect(external).toEqual([]);
});

test("Deny leaves the live page unpublished and the draft editable", async ({
  page,
}) => {
  const frame = await openAgent(page);
  await frame.locator(".agent-session .run").click();
  await expect(
    frame.getByRole("button", { exact: true, name: "Deny" })
  ).toBeVisible({ timeout: 15_000 });
  const stop = await frame.locator(".agent-session .stop").boundingBox();
  const pane = await frame.locator(".sample-pane").first().boundingBox();

  if (!stop || !pane) {
    throw new Error("The live agent controls are missing.");
  }

  expect(stop.y + stop.height).toBeLessThanOrEqual(pane.y + pane.height + 1);
  await frame
    .getByRole("button", { exact: true, name: "Deny" })
    .click({ timeout: 15_000 });
  await expect(frame.locator(".agent-session")).toHaveAttribute(
    "data-agent-status",
    "denied"
  );
  await expect(frame.locator(".published")).toBeEmpty();
  await expect(
    frame.getByRole("textbox", { exact: true, name: "Project update" })
  ).not.toBeEmpty();
  await expect(
    frame.getByRole("button", { exact: true, name: "Publish update" })
  ).toBeEnabled();
  await expect(frame.locator(".agent-frame")).toHaveCount(0);
});

test("Stop dismisses a pending approval and late actions cannot publish", async ({
  page,
}) => {
  const frame = await openAgent(page);
  await frame.locator(".agent-session .run").click();
  await expect(
    frame.getByRole("button", { exact: true, name: "Allow Once" })
  ).toBeVisible({ timeout: 15_000 });
  await frame.locator(".agent-session .stop").click();
  await expect(frame.locator(".agent-session")).toHaveAttribute(
    "data-agent-status",
    "stopped"
  );
  await expect(
    frame.getByRole("button", { exact: true, name: "Allow Once" })
  ).toHaveCount(0);
  await expect(frame.locator(".agent-frame")).toHaveCount(0);
  await expect(frame.locator(".published")).toBeEmpty();
  await frame
    .getByRole("textbox", { exact: true, name: "Project update" })
    .fill("A visitor can keep editing.");
  await expect(
    frame.getByRole("textbox", { exact: true, name: "Project update" })
  ).toHaveValue("A visitor can keep editing.");
});

test("switching modes stops the live session and keeps personal tabs intact", async ({
  page,
}) => {
  const frame = await openAgent(page);
  await frame.locator(".agent-session .run").click();
  await expect(frame.locator(".agent-cursor")).toBeVisible();
  await page.locator("#browser-demo .demo-modes [data-action=browser]").click();
  await expect(
    frame.getByRole("treeitem", { exact: true, name: "Alexays / Lilo, Pinned" })
  ).toBeVisible();
  await expect(frame.locator(".agent-frame")).toHaveCount(0);
  await page.locator("#browser-demo .demo-modes [data-action=mcp]").click();
  await expect(frame.locator(".agent-session")).toHaveAttribute(
    "data-agent-status",
    "stopped"
  );
  await expect(frame.locator(".published")).toBeEmpty();
});

test("the French live session works on a narrow preview and cancels when hidden", async ({
  page,
}) => {
  await page.setViewportSize({ height: 851, width: 538 });
  const frame = await openAgent(page, true);
  await frame
    .getByRole("button", { exact: false, name: "Lancer avec Codex" })
    .click();
  await expect(frame.locator(".agent-session")).toHaveAttribute(
    "data-agent-status",
    "waiting",
    { timeout: 15_000 }
  );
  await expect(frame.locator(".agent-frame")).toContainText(
    "Codex contrôle cet onglet"
  );
  await page.locator("footer").scrollIntoViewIfNeeded();
  await expect(frame.locator(".agent-session")).toHaveAttribute(
    "data-agent-status",
    "stopped"
  );
  await expect(frame.locator(".published")).toBeEmpty();
  await expect(frame.locator(".prompt-actions")).toHaveCount(0);
});
