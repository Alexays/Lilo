import type { AnimationConfig } from "svelte/animate";

// Svelte's flip also scales resized rows (a folder growing around a drop placeholder), which
// squashes their children and defeats the drag engine's in-flight translation correction.
// Deferred, as Svelte runs a returned function a microtask later: `to` is read once entering siblings
// have collapsed to their first frame, so a row they push down rides along instead of jumping over them.
export function translateFlip(
	node: Element,
	{ from }: { from: DOMRect; to: DOMRect },
	{ duration = 0, easing }: { duration?: number; easing?: (t: number) => number } = {},
): AnimationConfig {
	const deferred = (): AnimationConfig => {
		const to = node.getBoundingClientRect();
		const dx = from.left - to.left;
		const dy = from.top - to.top;
		if (dx === 0 && dy === 0) return { duration: 0 };
		return {
			duration,
			easing,
			css: (_t, u) => `transform: translate(${u * dx}px, ${u * dy}px);`,
		};
	};
	return deferred as unknown as AnimationConfig;
}
