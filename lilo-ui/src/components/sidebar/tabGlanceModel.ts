// The glance card's size: the user resizes it once and every glance keeps that size, stored as "<width>x<height>".

export interface GlanceSize {
	width: number;
	height: number;
}

export const GLANCE_SIZE_SETTING = "tabGlanceSize";
export const GLANCE_DEFAULT_SIZE: GlanceSize = { width: 320, height: 400 };
const MIN: GlanceSize = { width: 260, height: 240 };
const MAX: GlanceSize = { width: 720, height: 900 };

export function parseGlanceSize(value: string): GlanceSize {
	const match = /^(\d{2,4})x(\d{2,4})$/.exec(value);
	return match ? { width: Number(match[1]), height: Number(match[2]) } : GLANCE_DEFAULT_SIZE;
}

export function formatGlanceSize(size: GlanceSize): string {
	return `${size.width}x${size.height}`;
}

/** Within the card's bounds and the room the window leaves it, whole pixels. */
export function clampGlanceSize(size: GlanceSize, room: GlanceSize): GlanceSize {
	const fit = (value: number, axis: keyof GlanceSize) =>
		Math.round(Math.max(Math.min(value, MAX[axis], room[axis]), MIN[axis]));
	return { width: fit(size.width, "width"), height: fit(size.height, "height") };
}
