import assert from "node:assert/strict";
import test from "node:test";
import { pageBarStyle } from "./pageBarTheme";

function variable(style: string | undefined, name: string): string | undefined {
	return style?.split("; ").find((entry) => entry.startsWith(`${name}: `))?.slice(name.length + 2);
}

test("a page bar takes the page's color unmixed, with text that reads on it", () => {
	const light = pageBarStyle("#ffffff", "#e2daf1");
	assert.equal(variable(light, "--sidebar-bg"), "#ffffff");
	assert.equal(variable(light, "--sidebar-contrast"), "#1d1d1f");

	const dark = pageBarStyle("#4a154b", "#e2daf1");
	assert.equal(variable(dark, "--sidebar-bg"), "#4a154b");
	assert.equal(variable(dark, "--sidebar-contrast"), "#f8f9fd");
});

test("the active tab stands apart from a white page", () => {
	const style = pageBarStyle("#ffffff", "#e2daf1");
	assert.notEqual(variable(style, "--sidebar-selected"), "#ffffff");
	assert.equal(variable(pageBarStyle("#fde7c8", "#e2daf1"), "--sidebar-selected"), "#ffffff");
});

test("stops read off a page's edge theme the bar over their average", () => {
	const style = pageBarStyle("#20104a,#2848d8", "#e2daf1");
	assert.equal(variable(style, "--sidebar-bg"), "#242c91");
	assert.equal(variable(style, "--sidebar-contrast"), "#f8f9fd");
});

test("a page without a color leaves the bars to the sidebar's", () => {
	assert.equal(pageBarStyle(undefined, "#e2daf1"), undefined);
	assert.equal(pageBarStyle("", "#e2daf1"), undefined);
});
