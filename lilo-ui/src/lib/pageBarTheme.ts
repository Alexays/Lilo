import { apcaLuminance, parseHexColor, prefersLightText, surfaceVariables, type RGB } from "./sidebarTheme";

/** The sidebar's variables re-derived over a page's own color, for what sits on the bar the native frame draws in it:
 * a page that takes light text read as the dark sidebar does, stops read off the page's edge over their average.
 * Undefined for a page without a color. */
export function pageBarStyle(pageColor: string | undefined, accentInput: string): string | undefined {
	const stops = (pageColor ?? "").split(",").map(parseHexColor);
	if (stops.some((stop) => !stop)) return undefined;
	const rgb = stops as RGB[];
	const average = (channel: keyof RGB) => Math.round(rgb.reduce((sum, stop) => sum + stop[channel], 0) / rgb.length);
	const page = { r: average("r"), g: average("g"), b: average("b") };
	const vars = surfaceVariables(page, parseHexColor(accentInput) ?? page, prefersLightText(page));
	// A white active tab on a white page would show only its edge: it takes a shade of the page instead.
	if (apcaLuminance(page) > 0.9) {
		vars["--sidebar-selected"] = vars["--sidebar-panel"];
		vars["--sidebar-sel"] = vars["--sidebar-panel"];
	}
	return Object.entries(vars).map(([name, value]) => `${name}: ${value}`).join("; ");
}
