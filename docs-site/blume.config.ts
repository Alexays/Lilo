import { readFileSync } from "node:fs";
import { defineConfig } from "blume";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf-8");
const version = read("../Xcode/Configs/Base.xcconfig").match(/MARKETING_VERSION = (\S+)/u)?.[1];
if (!version) {
  throw new Error("MARKETING_VERSION not found in Xcode/Configs/Base.xcconfig");
}

const inter = {
  name: "Inter",
  variants: [
    { src: "./fonts/inter-latin-wght-e868cdf4.woff2" },
    { src: "./fonts/inter-latin-wght-italic-91753f8d.woff2", style: "italic" as const },
  ],
};

export default defineConfig({
  title: "Lilo Docs",
  description:
    "Learn Lilo, the fast, private macOS browser built on WebKit: install it, import your browser, organize tabs in Spaces and connect your AI agents.",
  logo: { image: "/logo.svg", text: "Lilo" },
  content: { root: "content" },
  deployment: { site: "https://docs.getlilo.app" },
  github: { owner: "Alexays", repo: "Lilo", dir: "docs-site" },
  i18n: {
    defaultLocale: "en",
    locales: [
      { code: "en", label: "English" },
      {
        code: "fr",
        label: "Français",
        style:
          "French from France, vouvoiement, sentence-case headings; keep Lilo's terms exactly as the French interface names them; keyboard keys and menu paths as the French interface shows them; never translate tool names, parameter names, enum values or code",
      },
    ],
    routeByBrowserLanguage: true,
  },
  theme: {
    accent: { light: "#4a2fc8", dark: "#cdbaff" },
    background: { light: "#f7f4fc", dark: "#0f0f1a" },
    mode: "system",
    fonts: {
      display: inter,
      body: inter,
      mono: { name: "Geist Mono", variants: [{ src: "./fonts/geist-mono-latin-wght-181a2944.woff2" }] },
    },
  },
  navigation: {
    actions: [{ href: "https://getlilo.app/", label: { en: "getlilo.app", fr: "getlilo.app" } }],
    cta: {
      href: "https://github.com/Alexays/Lilo/releases/latest/download/Lilo.dmg",
      label: { en: "Download", fr: "Télécharger" },
    },
  },
  footer: {
    copyright: { en: "Free and open source, MIT License", fr: "Gratuit et open source, licence MIT" },
    links: [
      { label: { en: "Privacy", fr: "Confidentialité" }, href: "/about/privacy" },
      { label: { en: "Changelog", fr: "Nouveautés" }, href: "https://getlilo.app/changelog/" },
      { label: { en: "Report a bug", fr: "Signaler un bug" }, href: "https://github.com/Alexays/Lilo/issues" },
    ],
    socials: { discord: "https://discord.gg/NyJRAapk76" },
  },
  // GitHub's default light and dark code themes leave some tokens under AA on Lilo's backgrounds.
  markdown: { code: { theme: { light: "github-light-high-contrast", dark: "github-dark-default" } } },
  variables: { version, macos: "26" },
  seo: { sitemap: { alternates: true }, og: { image: "/og.png" } },
  agents: {
    llmsTxt: {
      details:
        "Lilo is a free, open-source macOS browser built on the system's WebKit, with Spaces, split view, Chrome extensions and a built-in MCP server that lets AI agents drive real tabs. Install it with `brew install --cask alexays/tap/lilo` or the DMG from GitHub releases. For the product overview, pricing and requirements, read https://getlilo.app/llms.txt.",
    },
  },
  feedback: false,
  poweredBy: false,
});
