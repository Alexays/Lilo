import type { Dash, Fill, Heads } from "../ink";

export type ToolKind = "select" | "arrow" | "rect" | "ellipse" | "text" | "highlight" | "blur" | "crop" | "badge" | "draw";
type AnnotationKind = Exclude<ToolKind, "select" | "crop">;

export interface Box {
	x: number;
	y: number;
	w: number;
	h: number;
}

interface Point {
	x: number;
	y: number;
}

export interface Annotation {
	id: string;
	type: AnnotationKind;
	box: Box;
	color: string;
	strokeWidth: number;
	text?: string;
	points?: Point[]; // freehand path (image-pixel coords); present only for type "draw"
	/** Rect and ellipse only. */
	fill?: Fill;
	/** Lines only: arrow, rect, ellipse, draw. */
	dash?: Dash;
	/** Arrow only. */
	heads?: Heads;
}

let counter = 0;

function nextId(): string {
	counter += 1;
	return `anno-${counter}`;
}

export function createAnnotation(
	type: AnnotationKind,
	box: Box,
	color: string,
	strokeWidth: number,
	text?: string,
): Annotation {
	return { id: nextId(), type, box: { ...box }, color, strokeWidth, text };
}

/** Returns an equivalent box with non-negative width/height. */
export function normalizeBox(box: Box): Box {
	return {
		x: box.w < 0 ? box.x + box.w : box.x,
		y: box.h < 0 ? box.y + box.h : box.y,
		w: Math.abs(box.w),
		h: Math.abs(box.h),
	};
}

function contains(box: Box, point: Point): boolean {
	const n = normalizeBox(box);
	return point.x >= n.x && point.x <= n.x + n.w && point.y >= n.y && point.y <= n.y + n.h;
}

/** Topmost annotation (last in paint order) whose box contains `point`, or null. */
export function hitTest(annotations: Annotation[], point: Point): Annotation | null {
	for (let i = annotations.length - 1; i >= 0; i -= 1) {
		if (contains(annotations[i].box, point)) return annotations[i];
	}
	return null;
}

export function moveAnnotation(annotation: Annotation, dx: number, dy: number): Annotation {
	return {
		...annotation,
		box: { ...annotation.box, x: annotation.box.x + dx, y: annotation.box.y + dy },
		points: annotation.points?.map((p) => ({ x: p.x + dx, y: p.y + dy })),
	};
}

export type Handle = "nw" | "n" | "ne" | "e" | "se" | "s" | "sw" | "w";

/** Returns a new annotation whose box has the dragged `handle` moved by (dx, dy). */
export function resizeAnnotation(annotation: Annotation, handle: Handle, dx: number, dy: number): Annotation {
	let { x, y, w, h } = annotation.box;
	if (handle.includes("w")) { x += dx; w -= dx; }
	if (handle.includes("e")) { w += dx; }
	if (handle.includes("n")) { y += dy; h -= dy; }
	if (handle.includes("s")) { h += dy; }
	return { ...annotation, box: { x, y, w, h } };
}

/** Axis-aligned bounding box of a freehand point list. */
export function boundsOfPoints(points: Point[]): Box {
	if (points.length === 0) return { x: 0, y: 0, w: 0, h: 0 };
	let minX = points[0].x, minY = points[0].y, maxX = points[0].x, maxY = points[0].y;
	for (const p of points) {
		if (p.x < minX) minX = p.x;
		if (p.y < minY) minY = p.y;
		if (p.x > maxX) maxX = p.x;
		if (p.y > maxY) maxY = p.y;
	}
	return { x: minX, y: minY, w: maxX - minX, h: maxY - minY };
}

/**
 * Quadratic segments through the midpoints of consecutive samples (each real point becomes a control point);
 * empty for no points, a tiny dot for a single point.
 */
export function smoothPath(points: Point[]): string {
	if (points.length === 0) return "";
	if (points.length === 1) {
		const p = points[0];
		return `M${p.x} ${p.y} l0 0`;
	}
	let d = `M${points[0].x} ${points[0].y}`;
	for (let i = 1; i < points.length - 1; i += 1) {
		const c = points[i];
		const mx = (points[i].x + points[i + 1].x) / 2;
		const my = (points[i].y + points[i + 1].y) / 2;
		d += ` Q${c.x} ${c.y} ${mx} ${my}`;
	}
	const last = points[points.length - 1];
	d += ` L${last.x} ${last.y}`;
	return d;
}
