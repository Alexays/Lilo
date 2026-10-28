import { cubicInOut } from "svelte/easing";
import type { EasingFunction, TransitionConfig } from "svelte/transition";

// Svelte's blur and fly read getComputedStyle as they start, forcing a style recalc in the middle of a tab
// switch. These assume the node rests at full opacity with no filter or transform, so they read nothing.

export function restingBlur(
	_node: Element,
	{ duration, easing = cubicInOut, amount, opacity }: { duration: number; easing?: EasingFunction; amount: number; opacity: number },
): TransitionConfig {
	return { duration, easing, css: (_t, u) => `opacity:${1 - (1 - opacity) * u};filter:blur(${u * amount}px)` };
}

export function restingFly(
	_node: Element,
	{ duration, easing, x, y }: { duration: number; easing: EasingFunction; x: number; y: number },
): TransitionConfig {
	return { duration, easing, css: (_t, u) => `transform:translate(${u * x}px,${u * y}px);opacity:${1 - u}` };
}
