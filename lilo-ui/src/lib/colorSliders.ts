// A color as two sliders, hue and intensity, at one lightness so every pick stays readable.

import { fromOklab, parseHexColor, toHex, toOklab } from "./sidebarTheme";

/** The lightness every slider color has, and the chroma at full intensity. */
export type ColorTone = { lightness: number; chroma: number };

export const SPACE_TONE: ColorTone = { lightness: 0.8, chroma: 0.16 };
export const FOLDER_TONE: ColorTone = { lightness: 0.72, chroma: 0.2 };

// Close enough to a preset, in the Oklab a/b plane, to take it and keep its name.
const SNAP_DISTANCE = 0.02;

export function colorToSliders(hex: string, tone: ColorTone): { hue: number; intensity: number } {
	const [, a, b] = toOklab(parseHexColor(hex) ?? { r: 128, g: 128, b: 128 });
	return {
		hue: ((Math.atan2(b, a) * 180) / Math.PI + 360) % 360,
		intensity: Math.min(Math.hypot(a, b) / tone.chroma, 1),
	};
}

export function slidersToColor(hue: number, intensity: number, tone: ColorTone, presets: readonly string[]): string {
	const angle = (hue * Math.PI) / 180;
	const a = Math.cos(angle) * intensity * tone.chroma;
	const b = Math.sin(angle) * intensity * tone.chroma;
	let nearest: string | undefined;
	let distance = SNAP_DISTANCE;
	for (const preset of presets) {
		const [, pa, pb] = toOklab(parseHexColor(preset)!);
		const d = Math.hypot(a - pa, b - pb);
		if (d < distance) [nearest, distance] = [preset, d];
	}
	return nearest ?? toHex(fromOklab(tone.lightness, a, b));
}
