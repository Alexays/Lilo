import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";
import { pluginFixtures } from "./pluginFixtures";

async function openPlugins(page: Page): Promise<void> {
	await bootChrome(page, { ...initialWorld(), plugins: pluginFixtures() });
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.locator(".section-nav-button").filter({ hasText: "Plugins" }).click();
	await expect(page.locator(".plugin-row")).toHaveCount(4);
}

const row = (page: Page, title: string) => page.locator(".plugin-row").filter({ hasText: title });
// The checkbox is the switch's invisible hit area; the track the user sees flips it.
const flip = (page: Page, name: string) => page.locator(".ui-toggle", { has: page.getByRole("checkbox", { name }) }).click();
const commands = async (page: Page, action: string) =>
	(await sentCommands(page)).filter((command) => command.action === action).map((command) => command.payload);

test("the list shows each plugin's version, permissions and state", async ({ page }) => {
	await openPlugins(page);
	await expect(page.locator(".plugin-row .row-name")).toHaveText(["Automations", "Connectors", "Reading List", "Broken Notes"]);
	await expect(row(page, "Automations").locator(".row-meta")).toHaveText("v1.2.0 · Run on a schedule, Read your tabs, Store its settings");
	await expect(row(page, "Automations").getByText("Running")).toBeVisible();
	await expect(row(page, "Connectors").getByText("Running")).toHaveCount(0);
	await expect(row(page, "Automations").getByRole("checkbox", { name: "Enable Automations" })).toBeChecked();
	await expect(row(page, "Reading List").getByRole("checkbox", { name: "Enable Reading List" })).not.toBeChecked();
});

test("a rejected manifest shows its reason and cannot be switched on", async ({ page }) => {
	await openPlugins(page);
	const broken = row(page, "Broken Notes");
	await expect(broken.locator(".row-meta")).toHaveText("Unknown capability \"page:edit\" in capabilities.");
	await expect(broken.getByRole("checkbox")).toBeDisabled();

	await broken.locator(".row-main").click();
	await expect(page.getByRole("alert")).toContainText("Can't run this plugin");
	await expect(page.getByRole("alert")).toContainText("Unknown capability \"page:edit\"");
	await expect(page.getByRole("heading", { name: "Permissions" })).toHaveCount(0);
});

test("enabling a plugin shows its permissions once; Cancel enables nothing", async ({ page }) => {
	await openPlugins(page);
	const toggle = row(page, "Reading List").getByRole("checkbox");
	await flip(page, "Enable Reading List");

	const sheet = page.getByRole("dialog", { name: "Enable Reading List?" });
	await expect(sheet).toBeVisible();
	await expect(sheet.getByRole("listitem")).toHaveText(["Read page content", "Act on pages (asks first)", "Use its own folder"]);
	await sheet.getByRole("button", { name: "Cancel" }).click();
	await expect(sheet).toHaveCount(0);
	await expect(toggle).not.toBeChecked();
	expect(await commands(page, "setPluginEnabled")).toEqual([]);

	await flip(page, "Enable Reading List");
	await page.getByRole("button", { name: "Enable", exact: true }).click();
	expect(await commands(page, "setPluginEnabled")).toEqual([{ id: "com.example.reading-list", enabled: true }]);
	await expect(toggle).toBeChecked();
	await expect(row(page, "Reading List").getByText("Running")).toBeVisible();
});

test("disabling needs no sheet and stops the plugin", async ({ page }) => {
	await openPlugins(page);
	await flip(page, "Enable Automations");
	await expect(page.getByRole("dialog")).toHaveCount(0);
	expect(await commands(page, "setPluginEnabled")).toEqual([{ id: "com.example.automations", enabled: false }]);
	await expect(row(page, "Automations").getByText("Running")).toHaveCount(0);
	await expect(row(page, "Automations").getByRole("checkbox")).not.toBeChecked();
});

test("each setting renders as its manifest type and commits its value", async ({ page }) => {
	await openPlugins(page);
	await row(page, "Reading List").locator(".row-main").click();

	const text = page.getByRole("textbox", { name: "Folder name" });
	const key = page.getByLabel("Sync key");
	await expect(text).toHaveValue("Reading");
	await expect(key).toHaveAttribute("type", "password");
	await expect(page.getByRole("combobox", { name: "Order" })).toHaveValue("Newest first");
	await expect(page.getByRole("checkbox", { name: "Notify when saved" })).toBeChecked();
	await expect(page.getByRole("textbox", { name: "Keep at most" })).toHaveValue("50");

	await text.fill("Later");
	await text.press("Enter");
	await key.fill("example-key");
	await key.blur();
	await page.getByRole("combobox", { name: "Order" }).selectOption("Oldest first");
	await flip(page, "Notify when saved");
	await page.getByRole("textbox", { name: "Keep at most" }).fill("20");
	await page.getByRole("textbox", { name: "Keep at most" }).blur();

	expect(await commands(page, "setPluginSetting")).toEqual([
		{ id: "com.example.reading-list", name: "folder", value: "Later" },
		{ id: "com.example.reading-list", name: "key", value: "example-key" },
		{ id: "com.example.reading-list", name: "order", value: "Oldest first" },
		{ id: "com.example.reading-list", name: "notify", value: false },
		{ id: "com.example.reading-list", name: "limit", value: 20 },
	]);
	// The host echoes the stored values back and the fields keep showing them.
	await expect(text).toHaveValue("Later");
	await expect(page.getByRole("textbox", { name: "Keep at most" })).toHaveValue("20");
});

test("a required setting says so until it is filled", async ({ page }) => {
	await openPlugins(page);
	await row(page, "Reading List").locator(".row-main").click();
	const account = page.locator("[data-setting-id='plugin:account']");
	await expect(account.locator(".ui-list-row-description")).toHaveText("Required");
	await account.getByRole("textbox").fill("me@example.com");
	await account.getByRole("textbox").blur();
	await expect(account.locator(".ui-list-row-description")).toHaveCount(0);
});

test("a permission is revoked on its own, and enabling again asks for that one only", async ({ page }) => {
	await openPlugins(page);
	await row(page, "Automations").locator(".row-main").click();

	await page.getByRole("button", { name: "Revoke Read your tabs from Automations" }).click();
	expect(await commands(page, "revokePluginCapability")).toEqual([{ id: "com.example.automations", capability: "tabs:read" }]);
	await expect(page.getByRole("button", { name: /^Revoke Read your tabs/ })).toHaveCount(0);
	await expect(page.locator(".ui-list-row").filter({ hasText: "Read your tabs" })).toContainText("Not allowed");
	await expect(page.getByRole("button", { name: /^Revoke Run on a schedule/ })).toBeVisible();

	await flip(page, "Enable Automations");
	await flip(page, "Enable Automations");
	const sheet = page.getByRole("dialog", { name: "Enable Automations?" });
	await expect(sheet.getByRole("listitem")).toHaveText(["Read your tabs"]);
});

test("Show in Finder and Stop Process act on the plugin; Stop shows only while it runs", async ({ page }) => {
	await openPlugins(page);
	await row(page, "Automations").locator(".row-main").click();

	await page.getByRole("button", { name: "Show in Finder" }).click();
	expect(await commands(page, "showPluginInFinder")).toEqual([{ id: "com.example.automations" }]);

	await page.getByRole("button", { name: "Stop Process" }).click();
	expect(await commands(page, "stopPlugin")).toEqual([{ id: "com.example.automations" }]);
	await expect(page.getByRole("button", { name: "Stop Process" })).toHaveCount(0);
});

test("the switches and rows are reachable from the keyboard", async ({ page }) => {
	await openPlugins(page);
	const first = row(page, "Automations");
	await first.locator(".row-main").focus();
	await page.keyboard.press("Tab");
	await expect(first.getByRole("checkbox")).toBeFocused();
	await page.keyboard.press("Space");
	await expect(page.getByRole("dialog")).toHaveCount(0);
	expect(await commands(page, "setPluginEnabled")).toEqual([{ id: "com.example.automations", enabled: false }]);
	await page.keyboard.press("Tab");
	await expect(row(page, "Connectors").locator(".row-main")).toBeFocused();
	await page.keyboard.press("Enter");
	await expect(page.getByRole("button", { name: "Show in Finder" })).toBeVisible();
});
