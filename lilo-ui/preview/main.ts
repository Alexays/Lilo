// The chrome UI in any browser, against the e2e fake host seeded with a sample world (make ui-preview).
// ?world=default|empty|onboarding, &theme=light|dark (the system's otherwise), &open=settings|commandbar,
// &tabs=left|right|top|bottom, &update=1 (a downloaded update waiting for a relaunch).
import type { Page } from "@playwright/test";
import pixelIcon from "../../Lilo/Resources/AppIcons/pixel.png?inline";
import { installFakeHost, type FakeHostWorld } from "../e2e/fakeHost";
import { LILO_SHORTCUT_KEYS } from "../e2e/fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

const params = new URLSearchParams(location.search);
const worldName = params.get("world") ?? "default";

const WORK = "space-work";
const HOME = "space-home";
const READING = "space-reading";

function defaultWorld(): FakeHostWorld {
	const site = (id: string, spaceId: string, title: string, url: string, flags: { isPinned?: boolean; isBookmarked?: boolean } = {}) =>
		tab(id, spaceId, { title, url, ...flags });
	return {
		spaces: [
			{ id: WORK, name: "Work", icon: "💼", color: "#5b7cfa", profileId: "profile-work", isPrivate: false, sortOrder: 0 },
			{ id: HOME, name: "Personal", icon: "🏡", color: "#e0805a", profileId: "profile-personal", isPrivate: false, sortOrder: 1 },
			{ id: READING, name: "Reading", icon: "📚", color: "#3fa37a", profileId: "profile-personal", isPrivate: false, sortOrder: 2 },
		],
		profiles: [
			{ id: "profile-personal", name: "Personal", isDefault: true, color: "#f1a7a5" },
			{ id: "profile-work", name: "Work", isDefault: false, color: "#b39df4" },
		],
		activeProfileId: "profile-work",
		activeSpaceId: WORK,
		shortcutKeys: LILO_SHORTCUT_KEYS,
		activeTabBySpace: { [WORK]: "tab-runes", [HOME]: "tab-recipes", [READING]: "tab-essay" },
		foldersBySpace: {
			[WORK]: [
				{ id: "folder-release", spaceId: WORK, name: "Release 0.2", color: "#5b7cfa", isCollapsed: false },
				{ id: "folder-design", spaceId: WORK, name: "Design", color: "#d97a2b", isCollapsed: true },
			],
		},
		tabsBySpace: {
			[WORK]: [
				site("tab-mail", WORK, "Inbox (3)", "https://mail.example.com/inbox", { isBookmarked: true }),
				site("tab-calendar", WORK, "Calendar", "https://calendar.example.com/week", { isBookmarked: true }),
				site("tab-chat", WORK, "Team chat", "https://chat.example.com/general", { isBookmarked: true }),
				site("tab-repo", WORK, "Alexays/Lilo", "https://github.com/Alexays/Lilo", { isPinned: true }),
				site("tab-board", WORK, "Sprint board", "https://board.example.com/sprint", { isPinned: true }),
				site("tab-pr", WORK, "Sidebar folders by a contributor · Pull Request #412", "https://github.com/Alexays/Lilo/pull/412", { isPinned: true }),
				site("tab-ci", WORK, "CI · Actions run", "https://github.com/Alexays/Lilo/actions", { isPinned: true }),
				site("tab-tokens", WORK, "Design tokens", "https://design.example.com/tokens", { isPinned: true }),
				site("tab-runes", WORK, "Runes · Svelte docs", "https://svelte.dev/docs/svelte/what-are-runes"),
				site("tab-container", WORK, "CSS container queries - MDN", "https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_containment/Container_queries"),
				site("tab-webkit", WORK, "WebKit Features in Safari", "https://webkit.org/blog/"),
			],
			[HOME]: [
				site("tab-music", HOME, "Radio", "https://radio.example.com", { isPinned: true }),
				site("tab-recipes", HOME, "Weeknight recipes", "https://recipes.example.com/weeknight"),
				site("tab-trip", HOME, "Trip planning", "https://maps.example.com/trip"),
			],
			[READING]: [site("tab-essay", READING, "On writing well", "https://essays.example.com/writing")],
		},
		treeItemsBySpace: {
			[WORK]: [
				treeItem("tab-mail", WORK, 0, "bookmarked"),
				treeItem("tab-calendar", WORK, 1, "bookmarked"),
				treeItem("tab-chat", WORK, 2, "bookmarked"),
				treeItem("tab-repo", WORK, 3, "pinned"),
				treeItem("tab-board", WORK, 4, "pinned"),
				treeItem("folder-release", WORK, 5, "pinned", "folder"),
				treeItem("tab-pr", WORK, 6, "pinned", "tab", "folder-release"),
				treeItem("tab-ci", WORK, 7, "pinned", "tab", "folder-release"),
				treeItem("folder-design", WORK, 8, "pinned", "folder"),
				treeItem("tab-tokens", WORK, 9, "pinned", "tab", "folder-design"),
				treeItem("tab-runes", WORK, 10),
				treeItem("tab-container", WORK, 11),
				treeItem("tab-webkit", WORK, 12),
			],
			[HOME]: [
				treeItem("tab-music", HOME, 0, "pinned"),
				treeItem("tab-recipes", HOME, 1),
				treeItem("tab-trip", HOME, 2),
			],
			[READING]: [treeItem("tab-essay", READING, 0)],
		},
	};
}

// A first launch: one Space with one blank tab.
function emptyWorld(): FakeHostWorld {
	return {
		spaces: [{ id: HOME, name: "Home", icon: "🏡", color: "#5865f2", profileId: "profile-personal", isPrivate: false, sortOrder: 0 }],
		activeSpaceId: HOME,
		shortcutKeys: LILO_SHORTCUT_KEYS,
		activeTabBySpace: { [HOME]: "tab-blank" },
		tabsBySpace: { [HOME]: [tab("tab-blank", HOME, { url: "", title: "" })] },
		treeItemsBySpace: { [HOME]: [treeItem("tab-blank", HOME, 0)] },
	};
}

// The classic icon's four petals (Lilo/Resources/AppIcon.icon) on its light backdrop.
function appIcon(): string {
	const petal = "M0,-12 C58,-28 114,-108 114,-202 C114,-286 64,-344 0,-344 C-64,-344 -114,-286 -114,-202 C-114,-108 -58,-28 0,-12Z";
	const petals = [[135, "#7C5DEE", "#4A2FC8"], [-135, "#A88DF8", "#795CEB"], [45, "#CDBAFF", "#9C82F6"], [-45, "#E4D8FF", "#B7A0FF"]] as const;
	const defs = petals.map(([, from, to], i) => `<linearGradient id="p${i}" x1=".15" y1="0" x2=".85" y2="1"><stop offset="0" stop-color="${from}"/><stop offset="1" stop-color="${to}"/></linearGradient>`).join("");
	const paths = petals.map(([angle], i) => `<path transform="translate(512 512) rotate(${angle}) scale(1.12)" d="${petal}" fill="url(#p${i})"/>`).join("");
	const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><defs><linearGradient id="bg" x2="0" y2="1"><stop offset="0" stop-color="#FCFAFF"/><stop offset="1" stop-color="#E8DEFF"/></linearGradient>${defs}</defs><rect width="1024" height="1024" fill="url(#bg)"/>${paths}</svg>`;
	return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

function extension(id: string, name: string, color: string, extra: { badgeText?: string; isEnabled?: boolean } = {}) {
	const icon = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="8" fill="${color}"/><text x="16" y="22" font-family="system-ui" font-size="16" font-weight="600" fill="#fff" text-anchor="middle">${name[0]}</text></svg>`;
	return {
		id, name, version: "1.4.2", description: `${name}, loaded by the preview`, isEnabled: true,
		iconDataURL: `data:image/svg+xml,${encodeURIComponent(icon)}`,
		hasPopup: true, hasBackground: true, hasContentScripts: true, badgeText: "", badgeColor: "#5b5bd6",
		...extra,
	};
}

const settings: Record<string, string> = {
	searchEngine: "duckduckgo",
	contentBlockerEnabled: "true",
	agentControlEnabled: "true",
	externalLinkRules: JSON.stringify([{ match: "host", pattern: "github.com", destination: "little" }]),
};

// The answers the Swift side gives to what the surfaces ask for when they open.
const replies: Record<string, () => Record<string, unknown>> = {
	getSettings: () => ({ event: "settingsLoaded", settings }),
	getAppIcons: () => ({ event: "appIconsLoaded", icons: [
		{ id: "classic", dataURL: appIcon() },
		{ id: "pixel", dataURL: pixelIcon },
	] }),
	dismissUpdate: () => ({ event: "updateReady", version: null }),
	scanImportSources: () => ({
		event: "importSourcesLoaded",
		sources: [
			{ id: "chrome", name: "Chrome", family: "chromium", iconDataURL: "", needsFullDiskAccess: false, profiles: [{ id: "Default", name: "Personal", kinds: ["bookmarks", "history", "passwords"], extensions: [] }] },
			{ id: "safari", name: "Safari", family: "safari", iconDataURL: "", needsFullDiskAccess: true, profiles: [] },
		],
	}),
};

const theme = params.get("theme");
const systemTheme = matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
if ((theme === "light" || theme === "dark") && theme !== systemTheme) {
	// A page cannot set prefers-color-scheme, so the queries that read it are inverted instead,
	// in every stylesheet Vite injects (on load and on each hot update) and in matchMedia.
	const invert = (query: string) =>
		query.replace(/prefers-color-scheme:\s*(dark|light)/g, (_, scheme) => `prefers-color-scheme: ${scheme === "dark" ? "light" : "dark"}`);
	const inverted = new WeakSet<CSSRule>();
	const invertRules = (rules: CSSRuleList) => {
		for (const rule of rules) {
			if (rule instanceof CSSMediaRule && !inverted.has(rule)) {
				inverted.add(rule);
				rule.media.mediaText = invert(rule.media.mediaText);
			}
			if (rule instanceof CSSGroupingRule) invertRules(rule.cssRules);
		}
	};
	const invertSheets = () => {
		for (const sheet of document.styleSheets) invertRules(sheet.cssRules);
	};
	new MutationObserver(invertSheets).observe(document.head, { childList: true, subtree: true, characterData: true });
	const systemMatchMedia = window.matchMedia.bind(window);
	window.matchMedia = (query) => systemMatchMedia(invert(query));
	document.documentElement.style.colorScheme = theme;
}

const page = { addInitScript: async <T>(script: (arg: T) => void, arg: T) => script(arg) };
const world = worldName === "default" ? defaultWorld() : emptyWorld();
const tabs = params.get("tabs");
if (tabs === "left" || tabs === "right" || tabs === "top" || tabs === "bottom") world.tabPosition = tabs;
await installFakeHost(page as unknown as Page, world);

const host = window.webkit!.messageHandlers!.lilo!;
const fakeHostPost = host.postMessage;
host.postMessage = (message) => {
	fakeHostPost(message);
	if (message.action === "setSetting") {
		const { key, value } = message.payload as { key: string; value: string };
		settings[key] = value;
	}
	const reply = replies[message.action];
	if (reply) setTimeout(() => window.__lilo?.receive(reply()), 0);
};

await import("../src/main");

// The overlays' chunk loads after the first frame, and with it the listeners for what follows.
if (!document.querySelector(".banner-host")) {
	await new Promise<void>((resolve) => {
		const observer = new MutationObserver(() => {
			if (!document.querySelector(".banner-host")) return;
			observer.disconnect();
			resolve();
		});
		observer.observe(document.body, { childList: true, subtree: true });
	});
}

const lilo = window.__lilo!;
if (worldName === "default") {
	const extensions = [
		extension("ext-blocker", "uBlock Origin", "#800000", { badgeText: "12" }),
		extension("ext-vault", "Bitwarden", "#175ddc"),
		extension("ext-marks", "Raindrop", "#2b7de9"),
		extension("ext-dark", "Dark Reader", "#3a3a3a", { isEnabled: false }),
	];
	lilo.receive({ event: "extensionsChanged", ids: extensions.map((e) => e.id), extensions });
}
if (params.get("update") === "1") lilo.receive({ event: "updateReady", version: "0.3.4" });
if (worldName === "onboarding") lilo.receive({ event: "onboardingState", show: true, step: 0, usage: "browse" });
const open = params.get("open");
if (open === "settings") lilo.receive({ event: "openSettings" });
if (open === "commandbar") lilo.receive({ event: "toggleCommandBar" });
