// Svelte transitions need an easing function: this is the same under-damped spring that
// --motion-ease-bounce (global.css) samples for CSS and the Web Animations API.
const DAMPING = 0.75;
const OMEGA = 6.2 / DAMPING;
const DAMPED_OMEGA = OMEGA * Math.sqrt(1 - DAMPING * DAMPING);

export function springEase(t: number): number {
	if (t <= 0) return 0;
	if (t >= 1) return 1;
	const envelope = Math.exp(-DAMPING * OMEGA * t);
	return 1 - envelope * (Math.cos(DAMPED_OMEGA * t) + (DAMPING * OMEGA / DAMPED_OMEGA) * Math.sin(DAMPED_OMEGA * t));
}
