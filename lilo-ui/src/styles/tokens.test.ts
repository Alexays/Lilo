import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { test } from "node:test";

const componentsRoot = new URL("../components/", import.meta.url).pathname;

// Components that paint fixed artwork rather than chrome, so their literal colors are the point.
const colorAllowlist = new Set([
	"diagnostics/DesignSystemShell.svelte", // a sample extension's own icon
	"onboarding/OnboardingAppearance.svelte", // theme previews
	"onboarding/OnboardingImport.svelte", // other browsers' brand colors
	"onboarding/OnboardingIntro.svelte", // the welcome backdrop
	"onboarding/OnboardingTips.svelte", // illustrations
	"onboarding/OnboardingUsage.svelte", // illustrations
	"screenshot/ScreenshotEditor.svelte", // always-dark editing canvas
	"settings/ThemePicker.svelte", // previews of each theme's own palette
]);

function svelteFiles(dir: string): string[] {
	return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
		const path = join(dir, entry.name);
		if (entry.isDirectory()) return svelteFiles(path);
		return entry.name.endsWith(".svelte") ? [path] : [];
	});
}

// Style blocks without comments, url(...) payloads (embedded SVG art) or masks (alpha only).
function styles(path: string): string {
	const source = readFileSync(path, "utf8");
	return [...source.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)]
		.map((match) => match[1])
		.join("\n")
		.replace(/\/\*[\s\S]*?\*\//g, "")
		.replace(/url\((?:"[^"]*"|'[^']*'|[^)]*)\)/g, "url()")
		.replace(/(?<![-\w])(?:-webkit-)?mask(?:-image)?\s*:[^;{}]*/g, "");
}

const files = svelteFiles(componentsRoot).map((path) => ({ name: relative(componentsRoot, path), css: styles(path) }));

test("component styles take colors from theme tokens, not literals", () => {
	const literal = /#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?)\(\s*[\d.]/g;
	const offenders = files
		.filter((file) => !colorAllowlist.has(file.name))
		.flatMap((file) => (file.css.match(literal) ?? []).map((color) => `${file.name}: ${color}`));
	assert.deepEqual(offenders, [], "use a token from styles/global.css (see styles/README.md)");
});

test("component radii and font sizes come from the token scales", () => {
	const declaration = /(?<![-\w])(border(?:-[a-z]+)*-radius|font-size)\s*:\s*([^;{}]+)/g;
	const pixels = /(?<![\w.(-])\d*\.?\d+px/;
	const offenders = files.flatMap((file) =>
		[...file.css.matchAll(declaration)]
			.filter(([, , value]) => pixels.test(value.replace(/(?:calc|clamp)\([^;]*\)/g, "")))
			.map(([, property, value]) => `${file.name}: ${property}: ${value.trim()}`),
	);
	assert.deepEqual(offenders, [], "use --radius-* or --font-size-* (see styles/README.md)");
});
