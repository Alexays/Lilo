import type { Annotation, Box } from "./annotationModel";
import { normalizeBox } from "./annotationModel";

interface ImageSize {
	w: number;
	h: number;
}

/** Blur strength in image pixels, shared with the editor preview so what is hidden on screen stays hidden. */
export const BLUR_RADIUS_PX = 10;

/** Clamps a (possibly null / negative / out-of-bounds) crop rect into the image, normalized. */
export function clampCrop(crop: Box | null, image: ImageSize): Box {
	if (!crop) return { x: 0, y: 0, w: image.w, h: image.h };
	const n = normalizeBox(crop);
	// Clamp each edge independently so a negative origin shrinks the box (the far edge stays put)
	// rather than shifting it.
	const x1 = Math.max(0, Math.min(n.x, image.w));
	const y1 = Math.max(0, Math.min(n.y, image.h));
	const x2 = Math.max(0, Math.min(n.x + n.w, image.w));
	const y2 = Math.max(0, Math.min(n.y + n.h, image.h));
	return { x: x1, y: y1, w: Math.max(0, x2 - x1), h: Math.max(0, y2 - y1) };
}

/**
 * Composites the base image, blur regions, and a serialized SVG annotation layer onto an offscreen
 * canvas at native resolution, cropped to `crop`, and returns a PNG data URL. Runtime-only (needs DOM).
 */
export async function flattenToPNG(
	baseImage: HTMLImageElement,
	svgEl: SVGSVGElement,
	blurRegions: Annotation[],
	crop: Box | null,
): Promise<string> {
	const image = { w: baseImage.naturalWidth, h: baseImage.naturalHeight };
	const region = clampCrop(crop, image);

	const canvas = document.createElement("canvas");
	canvas.width = region.w;
	canvas.height = region.h;
	const ctx = canvas.getContext("2d");
	if (!ctx) throw new Error("2D context unavailable");

	// Shift so the crop origin maps to (0,0).
	ctx.translate(-region.x, -region.y);

	// 1. sharp base
	ctx.drawImage(baseImage, 0, 0, image.w, image.h);

	// 2. blur regions: redraw the base, blurred, clipped to each region's normalized box
	for (const b of blurRegions) {
		const box = normalizeBox(b.box);
		ctx.save();
		ctx.beginPath();
		ctx.rect(box.x, box.y, box.w, box.h);
		ctx.clip();
		ctx.filter = `blur(${BLUR_RADIUS_PX}px)`;
		ctx.drawImage(baseImage, 0, 0, image.w, image.h);
		ctx.filter = "none";
		ctx.restore();
	}

	// 3. rasterize the SVG annotation layer
	const svgString = new XMLSerializer().serializeToString(svgEl);
	const svgURL = `data:image/svg+xml;base64,${btoa(unescape(encodeURIComponent(svgString)))}`;
	await new Promise<void>((resolve, reject) => {
		const layer = new Image();
		layer.onload = () => {
			ctx.drawImage(layer, 0, 0, image.w, image.h);
			resolve();
		};
		layer.onerror = () => reject(new Error("SVG layer rasterization failed"));
		layer.src = svgURL;
	});

	return canvas.toDataURL("image/png");
}
