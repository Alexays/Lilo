import { clamp } from "./math";

export type RGB = {
	r: number;
	g: number;
	b: number;
};

const DEFAULT_LIGHT_SIDEBAR = "#e2daf1";
const DEFAULT_DARK_SIDEBAR = "#1a1a2e";
const LIGHT_CANVAS: RGB = { r: 250, g: 247, b: 255 };
const DARK_CANVAS: RGB = { r: 43, g: 47, b: 60 };
const DARK_CONTRAST = "#f8f9fd";
const LIGHT_CONTRAST_RGB: RGB = { r: 0x1d, g: 0x1d, b: 0x1f };
const DARK_CONTRAST_RGB: RGB = { r: 0xf8, g: 0xf9, b: 0xfd };
// APCA lightness contrast (Lc): fluent text, and icons or states.
export const TEXT_CONTRAST = 60;
// Secondary text under the system's Increase contrast.
export const MORE_TEXT_CONTRAST = 75;
export const ICON_CONTRAST = 45;
// Light text on the dark sidebar's lifted rows, above TEXT_CONTRAST so a dark sidebar stays deep, not merely legible.
const DARK_ROW_CONTRAST = 75;
// The dark sidebar's lifted rows, this far toward the text color, which its darkening keeps legible.
const DARK_SELECTED_LIFT = 0.2;
const ELEVATED_FILL = 0.08;
// The light-text selected surface, this far toward the text color.
const SELECTED_LIFT = 0.14;
const DARK_ACTIVE_LIFT = 0.28;
const ACTIVE_TAB_TINT = 0.18;
// The accent's least OKLCH chroma, unless the Space is a gray (under GRAY_CHROMA).
const ACCENT_CHROMA = 0.1;
const GRAY_CHROMA = 0.02;
// The least OKLCH chroma a darkened dark sidebar keeps (the Space's own when lower), so its hue stays visible.
const DARK_TINT_CHROMA = 0.06;
// How much of an open folder's block shows over the sidebar.
const FOLDER_OPEN_LAYER = 0.25;
const WHITE: RGB = { r: 255, g: 255, b: 255 };
const BLACK: RGB = { r: 0, g: 0, b: 0 };
const LIGHT_DANGER = "#d96a74";
const DARK_DANGER = "#ff8d96";

function expandHex(hex: string): string {
	if (hex.length !== 3) {
		return hex;
	}

	return hex
		.split("")
		.map((char) => `${char}${char}`)
		.join("");
}

export function parseHexColor(input: string): RGB | null {
	const trimmed = input.trim().replace(/^#/, "");
	const normalized = expandHex(trimmed);
	if (!/^[0-9a-fA-F]{6}$/.test(normalized)) {
		return null;
	}

	const value = Number.parseInt(normalized, 16);
	return {
		r: (value >> 16) & 0xff,
		g: (value >> 8) & 0xff,
		b: value & 0xff,
	};
}

// Absolute chroma, not HSV saturation: a near-black like GitHub's #151012 has high HSV
// saturation but would only gray a tint out.
export function isChromaticHex(input: string | undefined): boolean {
	const color = parseHexColor(input ?? "");
	if (!color) return false;
	return Math.max(color.r, color.g, color.b) - Math.min(color.r, color.g, color.b) > 40;
}

export function toHex({ r, g, b }: RGB): string {
	return `#${[r, g, b]
		.map((channel) => clamp(channel, 0, 255).toString(16).padStart(2, "0"))
		.join("")}`;
}

function mix(base: RGB, target: RGB, ratio: number): RGB {
	return {
		r: Math.round(base.r + (target.r - base.r) * ratio),
		g: Math.round(base.g + (target.g - base.g) * ratio),
		b: Math.round(base.b + (target.b - base.b) * ratio),
	};
}

export function interpolateHexColors(
	start: string | undefined,
	end: string | undefined,
	ratio: number,
): string {
	const startColor = parseHexColor(start ?? "");
	const endColor = parseHexColor(end ?? "");
	const clampedRatio = Math.max(0, Math.min(1, ratio));

	if (startColor && endColor) {
		return toHex(mix(startColor, endColor, clampedRatio));
	}

	if (startColor) {
		return toHex(startColor);
	}

	if (endColor) {
		return toHex(endColor);
	}

	return start?.trim() || end?.trim() || "";
}

function linearize(channel: number): number {
	const normalized = channel / 255;
	if (normalized <= 0.03928) {
		return normalized / 12.92;
	}

	return ((normalized + 0.055) / 1.055) ** 2.4;
}

// OKLab, with Bjorn Ottosson's matrices.
export function toOklab(color: RGB): [number, number, number] {
	const [r, g, b] = [linearize(color.r), linearize(color.g), linearize(color.b)];
	const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
	const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
	const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
	return [
		0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
	];
}

export function fromOklab(lightness: number, a: number, b: number): RGB {
	const l = lightness + 0.3963377774 * a + 0.2158037573 * b;
	const m = lightness - 0.1055613458 * a - 0.0638541728 * b;
	const s = lightness - 0.0894841775 * a - 1.291485548 * b;
	const [l3, m3, s3] = [l * l * l, m * m * m, s * s * s];
	const channel = (linear: number): number => {
		const v = clamp(linear, 0, 1);
		return Math.round((v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055) * 255);
	};
	return {
		r: channel(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
		g: channel(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
		b: channel(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.707614701 * s3),
	};
}

function tone(background: RGB, foreground: RGB, amount: number): string {
	return toHex(mix(background, foreground, amount));
}

/**
 * `foreground`, darkened on a light `background` or lightened on a dark one until it clears
 * `minimum` (APCA Lc); `fallback` (the text color) when even black or white does not.
 */
export function ensureContrast(foreground: string, background: string, minimum: number, fallback: string): string {
	const fg = parseHexColor(foreground);
	const bg = parseHexColor(background);
	if (!fg || !bg) return fallback;
	if (apcaContrast(fg, bg) >= minimum) return toHex(fg);
	const target = apcaContrast(BLACK, bg) >= apcaContrast(WHITE, bg) ? BLACK : WHITE;
	for (let step = 0.05; step <= 1.0001; step += 0.05) {
		const candidate = mix(fg, target, step);
		if (apcaContrast(candidate, bg) >= minimum) return toHex(candidate);
	}
	return fallback;
}

export function deriveSidebarThemeVariables(
	input: string | undefined,
	prefersDark: boolean,
	glass = false,
): Record<string, string> {
	const fallback = prefersDark ? DEFAULT_DARK_SIDEBAR : DEFAULT_LIGHT_SIDEBAR;
	const fallbackColor = parseHexColor(fallback) ?? LIGHT_CANVAS;
	const accentSource = parseHexColor(input ?? "") ?? fallbackColor;
	if (!prefersDark) return surfaceVariables(accentSource, accentSource, false, glass);
	const tinted = mix(accentSource, DARK_CANVAS, 0.58);
	const darkAccent = toHex(mix(accentSource, WHITE, 0.18));
	let sidebar = tinted;
	// Darken a too-light dark background in OKLCH, keeping the Space's hue, until primary text clears DARK_ROW_CONTRAST
	// on a lifted row and on that row tinted by the lightened Space color. NSColor+CSSHex mirrors it.
	const textFails = (candidate: RGB): boolean => {
		const accent = parseHexColor(ensureContrast(darkAccent, toHex(candidate), ICON_CONTRAST, DARK_CONTRAST)) ?? WHITE;
		const selected = mix(candidate, DARK_CONTRAST_RGB, DARK_SELECTED_LIFT);
		const activeTab = {
			r: selected.r + (accent.r - selected.r) * ACTIVE_TAB_TINT,
			g: selected.g + (accent.g - selected.g) * ACTIVE_TAB_TINT,
			b: selected.b + (accent.b - selected.b) * ACTIVE_TAB_TINT,
		};
		return (
			apcaContrast(DARK_CONTRAST_RGB, activeTab) < DARK_ROW_CONTRAST ||
			apcaContrast(DARK_CONTRAST_RGB, mix(candidate, DARK_CONTRAST_RGB, DARK_ACTIVE_LIFT)) < DARK_ROW_CONTRAST
		);
	};
	if (textFails(sidebar)) {
		const [lightness, a, b] = toOklab(accentSource);
		const [, ta, tb] = toOklab(tinted);
		const scale = Math.min(1, Math.max(DARK_TINT_CHROMA, Math.hypot(ta, tb)) / Math.hypot(a, b));
		for (let step = 1; step <= 100 && textFails(sidebar); step += 1) {
			sidebar = fromOklab(lightness - step / 100, a * scale, b * scale);
		}
	}
	return surfaceVariables(sidebar, accentSource, prefersDark, glass);
}

// APCA 0.0.98G luminance: WCAG 2's ratio favors dark text on saturated mid tones (a medium blue or red) that read
// far better with light text, so the text's polarity is chosen perceptually.
export function apcaLuminance(color: RGB): number {
	const y = 0.2126729 * (color.r / 255) ** 2.4 + 0.7151522 * (color.g / 255) ** 2.4 + 0.072175 * (color.b / 255) ** 2.4;
	return y > 0.022 ? y : y + (0.022 - y) ** 1.414;
}

/** APCA lightness contrast of `text` on `background`, as an absolute Lc (0 to about 106). */
export function apcaContrast(text: RGB, background: RGB): number {
	const t = apcaLuminance(text);
	const b = apcaLuminance(background);
	const contrast = b > t ? (b ** 0.56 - t ** 0.57) * 1.14 : (b ** 0.65 - t ** 0.62) * 1.14;
	return Math.abs(contrast) < 0.1 ? 0 : (Math.abs(contrast) - 0.027) * 100;
}

/** Whether light text reads better than dark text on `color`, by APCA: the polarity every surface's text takes. */
export function prefersLightText(color: RGB): boolean {
	return apcaContrast(DARK_CONTRAST_RGB, color) >= apcaContrast(LIGHT_CONTRAST_RGB, color);
}

/** `#1d1d1f` or `#f8f9fd`, whichever reads better on `color` by APCA; pure black or white of the same polarity when
 * that one is under the text threshold on the surface that moves furthest toward the text (cards, or the selected row under light text). */
function textColor(color: RGB): RGB {
	const light = prefersLightText(color);
	const soft = light ? DARK_CONTRAST_RGB : LIGHT_CONTRAST_RGB;
	if (apcaContrast(soft, mix(color, soft, light ? SELECTED_LIFT : ELEVATED_FILL)) >= TEXT_CONTRAST) return soft;
	return light ? WHITE : BLACK;
}

/**
 * The Space's own hue, its chroma raised to `ACCENT_CHROMA` (a gray stays gray), darkened, or lightened toward white when
 * no darker shade can, until it clears the icon threshold on the sidebar and on the selected surface, and its label,
 * white or `#1d1d1f`, the text one. Lightening fades the chroma with it: a clipped sRGB channel would turn the hue.
 */
function spaceAccent(source: RGB, sidebar: RGB, selected: RGB, fallback: RGB): { accent: RGB; label: RGB } {
	const [lightness, a, b] = toOklab(source);
	const chroma = Math.hypot(a, b);
	const scale = chroma < GRAY_CHROMA ? 1 : Math.max(chroma, ACCENT_CHROMA) / chroma;
	for (const direction of [-1, 1]) {
		for (let step = 0; step <= 100; step += 1) {
			const shifted = lightness + (direction * step) / 100;
			const fit = direction < 0 ? 1 : Math.max(0, Math.min(1, (1 - shifted) / (1 - lightness)));
			const accent = fromOklab(shifted, a * scale * fit, b * scale * fit);
			const label = apcaContrast(WHITE, accent) >= apcaContrast(LIGHT_CONTRAST_RGB, accent) ? WHITE : LIGHT_CONTRAST_RGB;
			if (
				apcaContrast(accent, sidebar) >= ICON_CONTRAST &&
				apcaContrast(accent, selected) >= ICON_CONTRAST &&
				apcaContrast(label, accent) >= TEXT_CONTRAST
			) {
				return { accent, label };
			}
		}
	}
	return { accent: fallback, label: textColor(fallback) };
}

/**
 * Every sidebar variable over `sidebar`, its accent drawn from `accentSource`. On `glass`, the opaque fills keep their
 * color at 70%, so the glass shows through them while their text keeps about the contrast it has on the solid fill.
 * Hover, pressed, separators and the selected surface are translucent layers, so they hold on glass as they are.
 */
export function surfaceVariables(sidebar: RGB, accentSource: RGB, prefersDark: boolean, glass = false): Record<string, string> {
	const sidebarHex = toHex(sidebar);
	const contrastColor = textColor(sidebar);
	const sidebarContrast = toHex(contrastColor);
	const darkText = apcaLuminance(contrastColor) < 0.5;
	// One selected surface for the selected row, the pinned tiles, the current Space and the update card: a lighter
	// shade of the sidebar, white over it under dark text, the text color over it under light text.
	const selectedLayer = darkText ? "#ffffff 40%" : `${sidebarContrast} ${SELECTED_LIFT * 100}%`;
	const selectedSolid = darkText ? mix(sidebar, WHITE, 0.4) : mix(sidebar, contrastColor, SELECTED_LIFT);
	const { accent, label } = spaceAccent(accentSource, sidebar, selectedSolid, contrastColor);
	const accentHex = toHex(accent);
	const accentHover = ensureContrast(
		toHex(mix(accent, contrastColor, prefersDark ? 0.1 : 0.16)),
		sidebarHex,
		ICON_CONTRAST,
		sidebarContrast,
	);
	const dangerSource =
		parseHexColor(prefersDark ? DARK_DANGER : LIGHT_DANGER) ?? contrastColor;
	const danger = toHex(
		mix(dangerSource, contrastColor, prefersDark ? 0.06 : 0.1),
	);
	const fill = (amount: number): string =>
		glass ? `color-mix(in srgb, ${tone(sidebar, contrastColor, amount)} 70%, transparent)` : tone(sidebar, contrastColor, amount);
	const layer = (percent: number): string => `color-mix(in srgb, ${sidebarContrast} ${percent}%, transparent)`;
	// Secondary text also sits on quiet fields (the address), a hover layer darker or lighter than the sidebar.
	const quietField = tone(sidebar, contrastColor, prefersDark ? 0.08 : 0.06);
	const secondary = ensureContrast(tone(sidebar, contrastColor, 0.76), quietField, TEXT_CONTRAST, sidebarContrast);
	const muted = ensureContrast(tone(sidebar, contrastColor, 0.58), sidebarHex, TEXT_CONTRAST, sidebarContrast);

	return {
		"--sidebar-bg": sidebarHex,
		"--sidebar-contrast": sidebarContrast,
		"--sidebar-secondary": secondary,
		"--sidebar-muted": muted,
		"--sidebar-secondary-more": ensureContrast(secondary, quietField, MORE_TEXT_CONTRAST, sidebarContrast),
		"--sidebar-muted-more": ensureContrast(muted, sidebarHex, MORE_TEXT_CONTRAST, sidebarContrast),
		"--sidebar-panel": fill(prefersDark ? 0.12 : 0.05),
		"--sidebar-subtle": fill(prefersDark ? 0.08 : 0.03),
		"--sidebar-hover": layer(prefersDark ? 8 : 6),
		"--sidebar-active": layer(prefersDark ? 12 : 10),
		"--sidebar-selected": prefersDark
			? fill(DARK_SELECTED_LIFT)
			: glass ? "color-mix(in srgb, #ffffff 70%, transparent)" : "#ffffff",
		"--sidebar-sel": `color-mix(in srgb, ${selectedLayer}, transparent)`,
		"--sidebar-sel-solid": toHex(selectedSolid),
		"--sidebar-sel-ring": layer(6),
		"--sidebar-elevated": fill(prefersDark ? 0.16 : ELEVATED_FILL),
		"--sidebar-border": tone(sidebar, contrastColor, prefersDark ? 0.24 : 0.14),
		"--sidebar-separator": layer(prefersDark ? 14 : 12),
		"--sidebar-accent": accentHex,
		"--sidebar-accent-hover": accentHover,
		"--sidebar-accent-text": toHex(label),
		"--sidebar-danger": ensureContrast(danger, sidebarHex, TEXT_CONTRAST, sidebarContrast),
		"--sidebar-shadow": prefersDark
			? "rgba(9, 12, 18, 0.28)"
			: "rgba(52, 63, 98, 0.14)",
	};
}

/**
 * A folder's open block, a layer of its hue taken away from the sidebar's text so text keeps its contrast on it, and
 * its color guarded to the icon threshold on the sidebar and on that block (the sidebar's text color when it cannot be).
 */
export function deriveFolderColorVariables(
	folderColor: string,
	sidebarBg: string,
	prefersDark: boolean,
): { "--folder-accent": string; "--folder-open-bg": string } {
	const sidebar = parseHexColor(sidebarBg) ?? (prefersDark ? DARK_CANVAS : LIGHT_CANVAS);
	const folder = parseHexColor(folderColor) ?? sidebar;
	const text = textColor(sidebar);
	const [, a, b] = toOklab(folder);
	const layer = fromOklab(apcaLuminance(text) < 0.5 ? 0.97 : 0.2, a, b);
	const open = toHex(mix(sidebar, layer, FOLDER_OPEN_LAYER));
	const textHex = toHex(text);
	return {
		"--folder-accent": ensureContrast(ensureContrast(toHex(folder), open, ICON_CONTRAST, textHex), sidebarBg, ICON_CONTRAST, textHex),
		"--folder-open-bg": `color-mix(in srgb, ${toHex(layer)} ${FOLDER_OPEN_LAYER * 100}%, transparent)`,
	};
}
