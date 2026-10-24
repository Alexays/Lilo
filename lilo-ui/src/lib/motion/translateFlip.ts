import type { AnimationConfig } from "svelte/animate";

// Svelte's flip also scales resized rows (a folder growing around a drop placeholder), which
// squashes their children and defeats the drag engine's in-flight translation correction.
export function translateFlip(
	_node: Element,
	{ from, to }: { from: DOMRect; to: DOMRect },
	{ duration = 0, easing }: { duration?: number; easing?: (t: number) => number } = {},
): AnimationConfig {
	const dx = from.left - to.left;
	const dy = from.top - to.top;
	if (dx === 0 && dy === 0) return { duration: 0 };
	return {
		duration,
		easing,
		css: (_t, u) => `transform: translate(${u * dx}px, ${u * dy}px);`,
	};
}
