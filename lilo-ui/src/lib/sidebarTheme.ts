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
const LIGHT_CONTRAST = "#1d1d1f";
const DARK_CONTRAST = "#f8f9fd";
const LIGHT_CONTRAST_RGB: RGB = { r: 0x1d, g: 0x1d, b: 0x1f };
const DARK_CONTRAST_RGB: RGB = { r: 0xf8, g: 0xf9, b: 0xfd };
// WCAG AA: text, and icons or states.
export const TEXT_CONTRAST = 4.5;
export const ICON_CONTRAST = 3;
// The dark theme's selected and active rows, lifted this far toward the text color.
const DARK_SELECTED_LIFT = 0.2;
const DARK_ACTIVE_LIFT = 0.28;
// The active tab row mixes this much of the accent into the selected row (TabItem's .active).
const ACTIVE_TAB_TINT = 0.18;
// The least OKLCH chroma a darkened dark sidebar keeps (the Space's own when lower), so its hue stays visible.
const DARK_TINT_CHROMA = 0.06;
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

function toHex({ r, g, b }: RGB): string {
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

function fromOklab(lightness: number, a: number, b: number): RGB {
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

export function relativeLuminance(color: RGB): number {
	return (
		0.2126 * linearize(color.r) +
		0.7152 * linearize(color.g) +
		0.0722 * linearize(color.b)
	);
}

export function contrastRatio(a: RGB, b: RGB): number {
	const la = relativeLuminance(a);
	const lb = relativeLuminance(b);
	return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

function pickContrast(color: RGB): string {
	return contrastRatio(color, DARK_CONTRAST_RGB) >= contrastRatio(color, LIGHT_CONTRAST_RGB)
		? DARK_CONTRAST
		: LIGHT_CONTRAST;
}

function tone(background: RGB, foreground: RGB, amount: number): string {
	return toHex(mix(background, foreground, amount));
}

/**
 * `foreground`, darkened on a light `background` or lightened on a dark one until it clears
 * `minimum`; `fallback` (the text color) when even black or white does not.
 */
export function ensureContrast(foreground: string, background: string, minimum: number, fallback: string): string {
	const fg = parseHexColor(foreground);
	const bg = parseHexColor(background);
	if (!fg || !bg) return fallback;
	if (contrastRatio(fg, bg) >= minimum) return toHex(fg);
	const target = relativeLuminance(bg) > 0.18 ? BLACK : WHITE;
	for (let step = 0.05; step <= 1.0001; step += 0.05) {
		const candidate = mix(fg, target, step);
		if (contrastRatio(candidate, bg) >= minimum) return toHex(candidate);
	}
	return fallback;
}

export function deriveSidebarThemeVariables(
	input: string | undefined,
	prefersDark: boolean,
): Record<string, string> {
	const fallback = prefersDark ? DEFAULT_DARK_SIDEBAR : DEFAULT_LIGHT_SIDEBAR;
	const fallbackColor = parseHexColor(fallback) ?? LIGHT_CANVAS;
	const accentSource = parseHexColor(input ?? "") ?? fallbackColor;
	const tinted = mix(
		accentSource,
		prefersDark ? DARK_CANVAS : LIGHT_CANVAS,
		prefersDark ? 0.58 : 0.72,
	);
	const darkAccent = toHex(mix(accentSource, WHITE, 0.18));
	let sidebar = tinted;
	// Darken a too-light dark background in OKLCH, keeping the Space's hue, until primary text clears AA
	// on its lightest rows: the active row and the active tab (accent mixed in). NSColor+CSSHex mirrors it.
	if (prefersDark) {
		const textFails = (candidate: RGB): boolean => {
			const accent = parseHexColor(ensureContrast(darkAccent, toHex(candidate), ICON_CONTRAST, DARK_CONTRAST)) ?? WHITE;
			const selected = mix(candidate, DARK_CONTRAST_RGB, DARK_SELECTED_LIFT);
			// Unrounded: the row blends it with color-mix(), past the 8-bit variables.
			const activeTab = {
				r: selected.r + (accent.r - selected.r) * ACTIVE_TAB_TINT,
				g: selected.g + (accent.g - selected.g) * ACTIVE_TAB_TINT,
				b: selected.b + (accent.b - selected.b) * ACTIVE_TAB_TINT,
			};
			return (
				contrastRatio(activeTab, DARK_CONTRAST_RGB) < TEXT_CONTRAST ||
				contrastRatio(mix(candidate, DARK_CONTRAST_RGB, DARK_ACTIVE_LIFT), DARK_CONTRAST_RGB) < TEXT_CONTRAST
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
	}
	const sidebarHex = toHex(sidebar);
	const sidebarContrast = pickContrast(sidebar);
	const contrastColor =
		parseHexColor(sidebarContrast) ??
		parseHexColor(prefersDark ? DARK_CONTRAST : LIGHT_CONTRAST) ??
		LIGHT_CANVAS;
	let accent = prefersDark ? parseHexColor(darkAccent) ?? accentSource : mix(accentSource, contrastColor, 0.08);
	// Light accents carry white labels, as macOS buttons do: darkened just enough for white to read on them.
	for (let step = 1; !prefersDark && step <= 20 && contrastRatio(WHITE, accent) < TEXT_CONTRAST; step += 1) {
		accent = mix(accent, BLACK, 0.05);
	}
	const accentHex = ensureContrast(toHex(accent), sidebarHex, ICON_CONTRAST, sidebarContrast);
	const accentHover = ensureContrast(
		toHex(mix(parseHexColor(accentHex) ?? accent, contrastColor, prefersDark ? 0.1 : 0.16)),
		sidebarHex,
		ICON_CONTRAST,
		sidebarContrast,
	);
	const accentText = prefersDark
		? ensureContrast(pickContrast(parseHexColor(accentHex) ?? accent), accentHex, TEXT_CONTRAST, sidebarContrast)
		: "#ffffff";
	const dangerSource =
		parseHexColor(prefersDark ? DARK_DANGER : LIGHT_DANGER) ?? contrastColor;
	const danger = toHex(
		mix(dangerSource, contrastColor, prefersDark ? 0.06 : 0.1),
	);

	return {
		"--sidebar-bg": sidebarHex,
		"--sidebar-contrast": sidebarContrast,
		"--sidebar-secondary": ensureContrast(tone(sidebar, contrastColor, 0.76), sidebarHex, TEXT_CONTRAST, sidebarContrast),
		"--sidebar-muted": ensureContrast(tone(sidebar, contrastColor, 0.58), sidebarHex, TEXT_CONTRAST, sidebarContrast),
		"--sidebar-panel": tone(sidebar, contrastColor, prefersDark ? 0.12 : 0.05),
		"--sidebar-subtle": tone(sidebar, contrastColor, prefersDark ? 0.08 : 0.03),
		"--sidebar-hover": tone(sidebar, contrastColor, prefersDark ? 0.18 : 0.1),
		"--sidebar-active": tone(sidebar, contrastColor, prefersDark ? DARK_ACTIVE_LIFT : 0.16),
		"--sidebar-selected": prefersDark
			? tone(sidebar, contrastColor, DARK_SELECTED_LIFT)
			: "#ffffff",
		"--sidebar-elevated": tone(
			sidebar,
			contrastColor,
			prefersDark ? 0.16 : 0.08,
		),
		"--sidebar-border": tone(sidebar, contrastColor, prefersDark ? 0.24 : 0.14),
		"--sidebar-separator": tone(
			sidebar,
			contrastColor,
			prefersDark ? 0.18 : 0.1,
		),
		"--sidebar-accent": accentHex,
		"--sidebar-accent-hover": accentHover,
		"--sidebar-accent-text": accentText,
		"--sidebar-danger": ensureContrast(danger, sidebarHex, TEXT_CONTRAST, sidebarContrast),
		"--sidebar-shadow": prefersDark
			? "rgba(9, 12, 18, 0.28)"
			: "rgba(52, 63, 98, 0.14)",
		"--sidebar-swatch-ring": tone(
			sidebar,
			contrastColor,
			prefersDark ? 0.28 : 0.18,
		),
	};
}

/**
 * A folder's colors over its open background: the tint an open folder draws, darkened a little in
 * dark mode, and the folder color guarded to 3:1 on it (the sidebar's text color when it cannot be).
 */
export function deriveFolderColorVariables(
	folderColor: string,
	sidebarBg: string,
	prefersDark: boolean,
): { "--folder-accent": string; "--folder-open-bg": string } {
	const sidebar = parseHexColor(sidebarBg) ?? (prefersDark ? DARK_CANVAS : LIGHT_CANVAS);
	const folder = parseHexColor(folderColor) ?? sidebar;
	let open = mix(sidebar, folder, prefersDark ? 0.14 : 0.11);
	if (prefersDark) open = mix(open, BLACK, 0.08);
	const openHex = toHex(open);
	return {
		"--folder-accent": ensureContrast(toHex(folder), openHex, ICON_CONTRAST, pickContrast(open)),
		"--folder-open-bg": openHex,
	};
}
