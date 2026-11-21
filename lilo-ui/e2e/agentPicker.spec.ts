import { test, expect, type Page } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld } from "./fixtures";

const names = [
	["claude-acp", "Claude Agent", "ACP wrapper for Anthropic's Claude", true],
	["codex-acp", "Codex", "ACP adapter for OpenAI's coding assistant", true],
	["gemini", "Gemini CLI", "Google's official CLI for Gemini", true],
	["github-copilot-cli", "Copilot", "AI pair programmer", true],
	["agoragentic-acp", "Agoragentic", "Agent marketplace with 174+ AI capabilities. Browse, invoke, and pay for agent services settled in USDC on Base L2."],
	["amp-acp", "Amp", "ACP wrapper for Amp"],
	["auggie", "Auggie CLI", "Augment Code's powerful software agent, backed by the leading context engine"],
	["autohand", "Autohand Code", "Autohand Code CLI with native ACP support"],
	["bob", "Bob", "IBM Bob is your AI-Powered Development Partner"],
	["cline", "Cline", "Autonomous coding agent CLI - capable of creating/editing files, running commands, using the browser, and more"],
	["codebuddy-code", "CodeBuddy Code", "Tencent Cloud's official intelligent coding tool"],
	["crow-cli", "crow-cli", "Minimal ACP Native Coding Agent"],
	["deepagents", "DeepAgents", "Batteries-included AI coding and general purpose agent harness, built by LangChain."],
	["dimcode", "DimCode", "A coding agent that puts leading models at your command."],
	["dirac", "Dirac", "Reduces API costs by more than 50%, produces better and faster work. Uses Hash"],
	["devin", "Devin", "The AI software engineer from Cognition"],
	["goose", "goose", "An open source AI agent that automates engineering tasks"],
	["junie", "Junie", "JetBrains' autonomous coding agent"],
	["kilo", "Kilo Code", "Open source AI coding assistant for VS Code"],
	["kimi", "Kimi", "Moonshot AI's coding assistant"],
	["mistral-vibe", "Mistral Vibe", "Mistral's CLI coding agent"],
	["opencode", "OpenCode", "Terminal-based AI coding agent"],
	["qwen-code", "Qwen Code", "Alibaba's agentic coding CLI"],
	["vtcode", "VT Code", "Semantic code analysis agent"],
] as const;

const agents = names.map(([id, name, description, featured]) => ({ id, name, description, ...(featured ? { featured: true } : {}) }));

async function openAskBar(page: Page) {
	await bootChrome(page, initialWorld());
	await page.evaluate((list) => {
		for (const message of list) window.__lilo!.receive(message as never);
	}, [
		{ event: "settingsLoaded", settings: { agentsEnabled: "true" } },
		{ event: "openAskBar", selection: "" },
		{ event: "agentCatalog", agents, projects: ["/Users/example/Code/acme"], home: "/Users/example" },
	]);
	return page.locator(".ask-bar");
}

test("agent picker rows keep their height, and the filter narrows a long list", async ({ page }) => {
	await page.setViewportSize({ width: 900, height: 700 });
	const bar = await openAskBar(page);
	await bar.getByRole("button", { name: "Agent", exact: true }).click();
	const rows = page.getByRole("menuitemradio");
	// The popover scales in from 0.96: measure once it rests.
	await page.getByRole("menu").evaluate((menu) => Promise.all(menu.getAnimations().map((animation) => animation.finished)));
	const boxes = await rows.evaluateAll((els) => els.map((el) => el.getBoundingClientRect()));
	const visible = boxes.filter((box) => box.bottom <= 700 && box.height > 0);
	for (let i = 1; i < visible.length; i++) expect(visible[i].top).toBeGreaterThanOrEqual(visible[i - 1].bottom);
	for (const box of visible) expect(box.height).toBe(40);
	await page.locator("[role='menu'] input[type='search']").fill("gem");
	await expect(rows).toHaveCount(1);
});
