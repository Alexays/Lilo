import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { test } from "node:test";

const componentsRoot = new URL("../components/", import.meta.url).pathname;

// Components that paint fixed artwork rather than chrome, so their literal colors are the point.
const colorAllowlist = new Set([
	"diagnostics/DesignSystemShell.svelte", // a sample extension's own icon
	"onboarding/OnboardingImport.svelte", // other browsers' brand colors
	"onboarding/OnboardingShell.svelte", // the welcome backdrop
	"onboarding/OnboardingUsage.svelte", // illustrations
	"onboarding/OnboardingYourLilo.svelte", // the window drawn over the wallpaper
	"screenshot/ScreenshotEditor.svelte", // always-dark editing canvas
	"settings/ThemePicker.svelte", // previews of each theme's own palette
	"spaces/AppearancePreview.svelte", // the window drawn over the wallpaper
]);

function svelteFiles(dir: string): string[] {
	return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
		const path = join(dir, entry.name);
		if (entry.isDirectory()) return svelteFiles(path);
		return entry.name.endsWith(".svelte") ? [path] : [];
	});
}

// CSS without comments, url(...) payloads (embedded SVG art) or masks (alpha only).
function clean(css: string): string {
	return css
		.replace(/\/\*[\s\S]*?\*\//g, "")
		.replace(/url\((?:"[^"]*"|'[^']*'|[^)]*)\)/g, "url()")
		.replace(/(?<![-\w])(?:-webkit-)?mask(?:-image)?\s*:[^;{}]*/g, "");
}

function styles(path: string): string {
	const source = readFileSync(path, "utf8");
	return clean([...source.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map((match) => match[1]).join("\n"));
}

// The tooltip injects its stylesheet from a template string rather than a component.
const tooltipCss = readFileSync(new URL("../lib/tooltip.ts", import.meta.url), "utf8").match(/textContent = `([\s\S]*?)`/)?.[1];
assert.ok(tooltipCss, "the tooltip stylesheet is no longer found in lib/tooltip.ts");

const files = [
	...svelteFiles(componentsRoot).map((path) => ({ name: relative(componentsRoot, path), css: styles(path) })),
	{ name: "../lib/tooltip.ts", css: clean(tooltipCss) },
];

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
