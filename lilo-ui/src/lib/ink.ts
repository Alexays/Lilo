// The capture editor's drawing vocabulary: swatches, widths, line styles and arrowheads.

type Point = { x: number; y: number };

export type Fill = "none" | "tint" | "solid";
export type Dash = "solid" | "dashed" | "dotted";
export type Heads = "none" | "end" | "both";
export type InkStyle = { color: string; width: number; fill: Fill; dash: Dash; heads: Heads };

// Named for the people who cannot tell the swatches apart.
export const INK_COLORS = [
	{ value: "#ff3b30", name: "red" },
	{ value: "#ffcc00", name: "yellow" },
	{ value: "#34c759", name: "green" },
	{ value: "#0a84ff", name: "blue" },
	{ value: "#ffffff", name: "white" },
	{ value: "#1c1c1e", name: "black" },
];

/** The tools both surfaces draw with: one name (`ink.tools.*`), icon and shortcut each. */
export const SHARED_TOOL_KEYS = { select: "V", arrow: "A", rect: "R", ellipse: "O", text: "T", pen: "P" } as const;

function headLength(width: number): number {
	return 8 + width * 2.5;
}

/** SVG path data of an arrow drawn in `box`: its shaft, and apart a head at each end that has one, kept solid on a dashed line. */
export function arrowPath(start: Point, end: Point, box: Point, width: number, heads: Heads): { shaft: string; heads: string } {
	const a = { x: start.x - box.x, y: start.y - box.y };
	const b = { x: end.x - box.x, y: end.y - box.y };
	const head = (tip: Point, from: Point): string => {
		const angle = Math.atan2(tip.y - from.y, tip.x - from.x);
		const length = headLength(width);
		const wing = (turn: number) =>
			`${(tip.x - length * Math.cos(angle + turn)).toFixed(1)} ${(tip.y - length * Math.sin(angle + turn)).toFixed(1)}`;
		return ` M${wing(0.45)} L${tip.x.toFixed(1)} ${tip.y.toFixed(1)} L${wing(-0.45)}`;
	};
	return {
		shaft: `M${a.x.toFixed(1)} ${a.y.toFixed(1)} L${b.x.toFixed(1)} ${b.y.toFixed(1)}`,
		heads: `${heads !== "none" ? head(b, a) : ""}${heads === "both" ? head(a, b) : ""}`.trim(),
	};
}

/** The stroke-dasharray of a line style, scaled to the line's width. */
export function dashArray(dash: Dash | undefined, width: number): string | undefined {
	if (dash === "dashed") return `${width * 4} ${width * 3}`;
	if (dash === "dotted") return `0 ${width * 2.5}`;
	return undefined;
}

/** `end` turned to the nearest 15 degrees around `start`, as Shift does in drawing tools. */
export function snapAngle(start: Point, end: Point): Point {
	const length = Math.hypot(end.x - start.x, end.y - start.y);
	const step = Math.PI / 12;
	const angle = Math.round(Math.atan2(end.y - start.y, end.x - start.x) / step) * step;
	return { x: start.x + length * Math.cos(angle), y: start.y + length * Math.sin(angle) };
}

/** Whether dark text reads better than white on a solid fill of `hex`. */
export function prefersDarkText(hex: string): boolean {
	const value = Number.parseInt(hex.replace("#", ""), 16);
	if (!Number.isFinite(value) || hex.length !== 7) return false;
	const channel = (shift: number) => {
		const c = ((value >> shift) & 0xff) / 255;
		return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
	};
	const luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0);
	return luminance > 0.4;
}
