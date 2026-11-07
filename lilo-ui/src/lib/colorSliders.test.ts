import assert from "node:assert/strict";
import test from "node:test";

import { colorToSliders, FOLDER_TONE, slidersToColor, SPACE_TONE } from "./colorSliders";
import { parseHexColor, toOklab } from "./sidebarTheme";
import { PASTEL_COLORS } from "../components/settings/profilesModel";

// stores/theme.svelte's FOLDER_COLORS, which needs a window to import.
const FOLDER_COLORS = ["#5b7cff", "#5fd79a", "#ffcc57", "#ff8a5b", "#f06aa6", "#9b7cff", "#4ecdc4", "#8a9ba8"];

test("a preset read into the sliders comes back as itself", () => {
	for (const [presets, tone] of [[PASTEL_COLORS, SPACE_TONE], [FOLDER_COLORS, FOLDER_TONE]] as const) {
		for (const preset of presets) {
			const { hue, intensity } = colorToSliders(preset, tone);
			assert.equal(slidersToColor(hue, intensity, tone, presets), preset);
		}
	}
});

test("a color away from every preset takes the tone's lightness", () => {
	const color = slidersToColor(200, 0.5, SPACE_TONE, []);
	const [lightness] = toOklab(parseHexColor(color)!);
	assert.ok(Math.abs(lightness - SPACE_TONE.lightness) < 0.01);
	const back = colorToSliders(color, SPACE_TONE);
	assert.ok(Math.abs(back.hue - 200) < 2 && Math.abs(back.intensity - 0.5) < 0.05);
});

test("no intensity is a gray, and intensity never reads past full", () => {
	const gray = parseHexColor(slidersToColor(120, 0, SPACE_TONE, []))!;
	assert.ok(gray.r === gray.g && gray.g === gray.b);
	assert.equal(colorToSliders("#ff0000", SPACE_TONE).intensity, 1);
});
