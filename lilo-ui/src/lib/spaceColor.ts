// The color a Space's chrome is derived from: its base color, lit by the time of day or taken from the page or wallpaper.

import type { SpaceColorMode } from "./bridge/protocol";
import { interpolateHexColors, isChromaticHex } from "./sidebarTheme";

export type DayPart = "morning" | "day" | "evening" | "night";

// Start hours, in day order.
const DAY_PARTS: [DayPart, number][] = [
	["morning", 6],
	["day", 11],
	["evening", 17],
	["night", 21],
];

const DAY_PART_LIGHT: Record<DayPart, [string, number]> = {
	morning: ["#ffffff", 0.2],
	day: ["#ffffff", 0],
	evening: ["#ff8a4c", 0.3],
	night: ["#1b1f3a", 0.35],
};

export function dayPart(hour: number): DayPart {
	return DAY_PARTS.findLast(([, start]) => hour >= start)?.[0] ?? "night";
}

export function msUntilNextDayPart(now: Date): number {
	const next = new Date(now);
	const start = DAY_PARTS.find(([, hour]) => hour > now.getHours())?.[1];
	if (start === undefined) next.setDate(next.getDate() + 1);
	next.setHours(start ?? DAY_PARTS[0][1], 0, 0, 0);
	return next.getTime() - now.getTime();
}

export function lightForDayPart(color: string, part: DayPart): string {
	const [light, amount] = DAY_PART_LIGHT[part];
	return amount ? interpolateHexColors(color, light, amount) : color;
}

/** A grey favicon or an unreadable wallpaper leaves the Space on its own color. */
export function effectiveSpaceColor(
	mode: SpaceColorMode | undefined,
	color: string,
	context: { dayPart: DayPart; pageColor?: string; wallpaperColor?: string },
): string {
	switch (mode) {
		case "time":
			return lightForDayPart(color, context.dayPart);
		case "page":
			// Mixed, not replaced: the Space stays recognizable from one site to the next.
			return isChromaticHex(context.pageColor) ? interpolateHexColors(color, context.pageColor, 0.6) : color;
		case "wallpaper":
			return context.wallpaperColor || color;
		default:
			return color;
	}
}
