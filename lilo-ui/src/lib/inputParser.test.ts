import test from "node:test";
import assert from "node:assert/strict";
import { COMMAND_ACTIONS, formatShortcut, parseInput, setTopLevelDomains } from "./inputParser";
import { TOP_LEVEL_DOMAINS } from "./topLevelDomains.gen";

test("parseInput treats chrome-extension:// URLs as navigate URLs", () => {
	const raw = "chrome-extension://d9eef443-b6ce-4936-adac-6ecb243419be/index.html#/onboarding";
	const parsed = parseInput(raw);

	assert.equal(parsed.type, "url");
	assert.equal(parsed.url, raw);
});

test("local hosts and IP addresses go over http unless a scheme is typed; other domains over https", () => {
	const expected: Record<string, string> = {
		"printer.local": "http://printer.local",
		"nas.local:5000/admin": "http://nas.local:5000/admin",
		"localhost:3000": "http://localhost:3000",
		"app.localhost:5173": "http://app.localhost:5173",
		"127.0.0.1:8080": "http://127.0.0.1:8080",
		"10.0.0.2": "http://10.0.0.2",
		"172.16.4.1": "http://172.16.4.1",
		"192.168.1.1/setup": "http://192.168.1.1/setup",
		"169.254.10.1": "http://169.254.10.1",
		"[::1]:8080": "http://[::1]:8080",
		"[fe80::1]": "http://[fe80::1]",
		"https://printer.local": "https://printer.local",
		"github.com": "https://github.com",
		"localhost.example.com": "https://localhost.example.com",
	};
	for (const [input, url] of Object.entries(expected)) {
		const parsed = parseInput(input);
		assert.equal(parsed.type, "url", input);
		assert.equal((parsed as { url?: string }).url, url, input);
	}
});

test("a name navigates when its last label is a top-level domain, or a port or path follows it", () => {
	setTopLevelDomains(TOP_LEVEL_DOMAINS);
	const expected: Record<string, string> = {
		"münchen.de": "https://münchen.de",
		"例え.テスト/ページ": "https://例え.テスト/ページ",
		"README.md": "https://README.md",
		"example.com.": "https://example.com.",
		"node.js/": "https://node.js/",
		"intranet.corp:8443": "https://intranet.corp:8443",
		"mailto:someone@example.com": "mailto:someone@example.com",
		"data:text/html,<h1>Hello there</h1>": "data:text/html,<h1>Hello there</h1>",
	};
	for (const [input, url] of Object.entries(expected)) {
		const parsed = parseInput(input);
		assert.equal(parsed.type, "url", input);
		assert.equal((parsed as { url?: string }).url, url, input);
	}
	for (const input of ["node.js", "package.json", "3.14", "localhostfoo", "localhost.js", "1.2.3.4.5", "10.0.0.256x", "intranet.corp"]) {
		assert.equal(parseInput(input).type, "search", input);
	}
});

test("absolute file path parses to a file:// URL", () => {
	const parsed = parseInput("/Users/me/page.html");
	assert.equal(parsed.type, "url");
	assert.equal((parsed as { url?: string }).url, "file:///Users/me/page.html");
});

test("file path with spaces is percent-encoded", () => {
	const parsed = parseInput("/Users/me/My Page.html");
	assert.equal(parsed.type, "url");
	assert.equal(
		(parsed as { url?: string }).url,
		"file:///Users/me/My%20Page.html",
	);
});

test("a single-segment /term stays a history search, not a file", () => {
	const parsed = parseInput("/recipes");
	assert.equal(parsed.scope, "history");
	assert.notEqual(parsed.type, "url");
});

test("known : command still resolves to an action", () => {
	const p = parseInput(": task manager", "all");
	assert.equal(p.type, "action");
	assert.ok((p as { action?: string }).action); // resolved CommandActionId
});

test("a bare single-word keyword without : is a search, not a command", () => {
	for (const word of ["zoom", "back", "stop", "mute", "private", "config", "flags", "bookmark", "sidebar"]) {
		const p = parseInput(word, "all");
		assert.equal(p.type, "search", word);
	}
});

test("a single-word keyword runs as a command under the : scope", () => {
	const p = parseInput(":zoom", "all");
	assert.equal(p.type, "action");
	assert.equal((p as { action?: string }).action, "zoomIn");
});

test("a single-word keyword runs as a command when the action scope is the default", () => {
	const p = parseInput("back", "action");
	assert.equal(p.type, "action");
	assert.equal((p as { action?: string }).action, "goBack");
});

test("a multi-word keyword without : still resolves to an action", () => {
	const p = parseInput("new tab", "all");
	assert.equal(p.type, "action");
	assert.equal((p as { action?: string }).action, "createTab");
});

test("unknown : command stays type action with no action id", () => {
	const p = parseInput(": close every tab about taxes", "all");
	assert.equal(p.type, "action");
	assert.equal((p as { action?: string }).action, undefined);
});

test("the command bar offers the Passwords app", () => {
	assert.ok(COMMAND_ACTIONS.some((action) => action.id === "openPasswordsApp"));
});

test("> runs a shell command, kept exactly as typed", () => {
	const p = parseInput(">  git log --oneline -5 ", "all");
	assert.equal(p.type, "terminal");
	assert.equal(p.scope, "terminal");
	assert.equal(p.query, "git log --oneline -5");
});

test("> never turns a command into a URL, an action or a search", () => {
	for (const command of ["example.com", "new tab", "zoom", "ls"]) {
		const p = parseInput(`>${command}`, "all");
		assert.equal(p.type, "terminal", command);
		assert.equal(p.query, command);
	}
});

test("formatShortcut writes modifiers in Mac menu order, then the key", () => {
	assert.equal(formatShortcut("Cmd+Shift+T"), "⇧⌘T");
	assert.equal(formatShortcut("Ctrl+Cmd+J"), "⌃⌘J");
	assert.equal(formatShortcut("Cmd+Opt+U"), "⌥⌘U");
	assert.equal(formatShortcut("Cmd++"), "⌘+");
	assert.equal(formatShortcut("Cmd+-"), "⌘-");
	assert.equal(formatShortcut("Cmd+Enter"), "⌘↩");
	assert.equal(formatShortcut("Enter"), "↩");
});
