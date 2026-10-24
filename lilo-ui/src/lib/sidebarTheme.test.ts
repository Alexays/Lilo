import assert from "node:assert/strict";
import test from "node:test";
import { contrastRatio, deriveFolderColorVariables, deriveSidebarThemeVariables, ensureContrast, ICON_CONTRAST, TEXT_CONTRAST } from "./sidebarTheme";

function rgb(hex: string): { r: number; g: number; b: number } {
	const value = Number.parseInt(hex.slice(1), 16);
	return { r: (value >> 16) & 0xff, g: (value >> 8) & 0xff, b: value & 0xff };
}

test("dark theme keeps primary text at AA contrast for a light accent", () => {
	for (const accent of ["#ffffff", "#ffe9a8", "#9ad6ff"]) {
		const vars = deriveSidebarThemeVariables(accent, true);
		const ratio = contrastRatio(rgb(vars["--sidebar-bg"]), rgb(vars["--sidebar-contrast"]));
		assert.ok(ratio >= 4.5, `${accent}: ${ratio.toFixed(2)}:1`);
	}
});

test("accent text picks the candidate with the higher measured contrast", () => {
	const vars = deriveSidebarThemeVariables("#ff6a00", false);
	const accent = rgb(vars["--sidebar-accent"]);
	const chosen = contrastRatio(accent, rgb(vars["--sidebar-accent-text"]));
	assert.ok(chosen >= contrastRatio(accent, rgb("#f8f9fd")));
	assert.ok(chosen >= contrastRatio(accent, rgb("#1d1d1f")));
});

test("ensureContrast leaves a passing color unchanged", () => {
	assert.equal(ensureContrast("#000000", "#ffffff", TEXT_CONTRAST, "#123456"), "#000000");
});

test("ensureContrast darkens on a light background and lightens on a dark one", () => {
	const onLight = ensureContrast("#c9b8f0", "#e2daf1", ICON_CONTRAST, "#1d1d1f");
	assert.ok(contrastRatio(rgb(onLight), rgb("#e2daf1")) >= ICON_CONTRAST);
	assert.ok(channelSum(onLight) < channelSum("#c9b8f0"));

	const onDark = ensureContrast("#3a3550", "#1a1a2e", ICON_CONTRAST, "#f8f9fd");
	assert.ok(contrastRatio(rgb(onDark), rgb("#1a1a2e")) >= ICON_CONTRAST);
	assert.ok(channelSum(onDark) > channelSum("#3a3550"));
});

test("ensureContrast falls back when no step reaches the threshold", () => {
	assert.equal(ensureContrast("#808080", "#808080", 21, "#1d1d1f"), "#1d1d1f");
});

test("every derived text and icon color clears its threshold", () => {
	for (const input of ["#b18cff", "#fff4cc", "#ffe9a8", "#9ad6ff", "#ff6a00", "#1a1a2e", undefined]) {
		for (const dark of [false, true]) {
			const vars = deriveSidebarThemeVariables(input, dark);
			const bg = rgb(vars["--sidebar-bg"]);
			const label = `${input ?? "default"} ${dark ? "dark" : "light"}`;
			for (const name of ["--sidebar-contrast", "--sidebar-secondary", "--sidebar-muted", "--sidebar-danger"]) {
				assert.ok(contrastRatio(rgb(vars[name]), bg) >= TEXT_CONTRAST, `${label} ${name}`);
			}
			assert.ok(contrastRatio(rgb(vars["--sidebar-accent"]), bg) >= ICON_CONTRAST, `${label} --sidebar-accent`);
			assert.ok(
				contrastRatio(rgb(vars["--sidebar-accent-text"]), rgb(vars["--sidebar-accent"])) >= TEXT_CONTRAST,
				`${label} accent text`,
			);
		}
	}
});

test("primary text clears AA on every row surface for any Space color", () => {
	const spaces = [
		"#000000", "#20242e", "#1a1a2e", "#3f4656", // very dark
		"#ffffff", "#fff4cc", "#e0ffff", "#ffffa0", // very light
		"#ff0000", "#00c000", "#0040ff", "#ff00ff", "#ffaa00", "#00e0e0", "#44dd77", "#aaee11", // saturated mid tones
	];
	const blend = (base: string, tint: string, amount: number) => {
		const [a, b] = [rgb(base), rgb(tint)];
		return { r: a.r + (b.r - a.r) * amount, g: a.g + (b.g - a.g) * amount, b: a.b + (b.b - a.b) * amount };
	};
	for (const space of spaces) {
		for (const dark of [false, true]) {
			const vars = deriveSidebarThemeVariables(space, dark);
			const text = rgb(vars["--sidebar-contrast"]);
			const label = `${space} ${dark ? "dark" : "light"}`;
			for (const surface of ["--sidebar-bg", "--sidebar-hover", "--sidebar-active", "--sidebar-selected"]) {
				const ratio = contrastRatio(text, rgb(vars[surface]));
				assert.ok(ratio >= TEXT_CONTRAST, `${label} on ${surface}: ${ratio.toFixed(2)}:1`);
			}
			// The active tab row: the selected row with 18% of the accent (TabItem's .active).
			const activeTab = contrastRatio(text, blend(vars["--sidebar-selected"], vars["--sidebar-accent"], 0.18));
			assert.ok(activeTab >= TEXT_CONTRAST, `${label} on the active tab: ${activeTab.toFixed(2)}:1`);
		}
	}
});

/** OKLCH lightness, chroma and hue in degrees of an 8-bit color. */
function oklch(hex: string): { l: number; c: number; h: number } {
	const linear = Object.values(rgb(hex)).map((channel) => {
		const v = channel / 255;
		return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
	});
	const [l, m, s] = [
		[0.4122214708, 0.5363325363, 0.0514459929],
		[0.2119034982, 0.6806995451, 0.1073969566],
		[0.0883024619, 0.2817188376, 0.6299787005],
	].map((row) => Math.cbrt(row[0] * linear[0] + row[1] * linear[1] + row[2] * linear[2]));
	const a = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
	const b = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;
	return {
		l: 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
		c: Math.hypot(a, b),
		h: ((Math.atan2(b, a) * 180) / Math.PI + 360) % 360,
	};
}

test("a dark sidebar keeps the hue of every palette and saturated Space color", () => {
	const spaces = [
		"#92a8ff", "#b39df4", "#f1a7a5", "#f4bb8c", "#e8d98f", "#9bd3b4", "#8fd5cf", "#9ac7eb", "#c3a5ea", "#f0a8c8", "#a7bcc7", "#c8ab98", // the editor's palette
		"#ff0000", "#0040ff", "#44dd77", "#ff00ff", "#ffaa00", "#aaee11", "#fff4cc",
	];
	for (const space of spaces) {
		const source = oklch(space);
		const sidebar = oklch(deriveSidebarThemeVariables(space, true)["--sidebar-bg"]);
		const drift = Math.abs(((sidebar.h - source.h + 540) % 360) - 180);
		assert.ok(drift <= 8, `${space}: hue ${sidebar.h.toFixed(0)} for ${source.h.toFixed(0)}`);
		assert.ok(sidebar.c >= 0.025, `${space}: chroma ${sidebar.c.toFixed(3)}`);
		assert.ok(sidebar.l <= 0.45, `${space}: lightness ${sidebar.l.toFixed(2)}`);
	}
});

test("the variable set is the same for every input", () => {
	assert.deepEqual(
		Object.keys(deriveSidebarThemeVariables("#b18cff", false)),
		Object.keys(deriveSidebarThemeVariables(undefined, false)),
	);
});

function channelSum(hex: string): number {
	const { r, g, b } = rgb(hex);
	return r + g + b;
}

test("every palette folder color clears 3:1 on its open folder", () => {
	const palette = ["#5b7cff", "#5fd79a", "#ffcc57", "#ff8a5b", "#f06aa6", "#9b7cff", "#4ecdc4", "#8a9ba8"];
	for (const space of ["#b18cff", "#1a1a2e"]) {
		for (const dark of [false, true]) {
			const sidebar = deriveSidebarThemeVariables(space, dark)["--sidebar-bg"];
			for (const color of palette) {
				const vars = deriveFolderColorVariables(color, sidebar, dark);
				const ratio = contrastRatio(rgb(vars["--folder-accent"]), rgb(vars["--folder-open-bg"]));
				assert.ok(ratio >= ICON_CONTRAST, `${color} on ${space} ${dark ? "dark" : "light"}: ${ratio.toFixed(2)}:1`);
			}
		}
	}
});
