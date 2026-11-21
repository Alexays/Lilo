// A CSS cubic-bezier as a Svelte easing function, for a transition that must match a CSS curve exactly.
export function cubicBezier(x1: number, y1: number, x2: number, y2: number): (t: number) => number {
	const ax = 3 * x1 - 3 * x2 + 1;
	const bx = 3 * x2 - 6 * x1;
	const cx = 3 * x1;
	const ay = 3 * y1 - 3 * y2 + 1;
	const by = 3 * y2 - 6 * y1;
	const cy = 3 * y1;
	const sampleX = (t: number) => ((ax * t + bx) * t + cx) * t;
	const sampleY = (t: number) => ((ay * t + by) * t + cy) * t;
	const sampleDX = (t: number) => (3 * ax * t + 2 * bx) * t + cx;
	return (x: number) => {
		if (x <= 0) return 0;
		if (x >= 1) return 1;
		let t = x;
		for (let i = 0; i < 6; i++) {
			const error = sampleX(t) - x;
			if (Math.abs(error) < 1e-4) return sampleY(t);
			const slope = sampleDX(t);
			if (Math.abs(slope) < 1e-6) break;
			t -= error / slope;
		}
		let lo = 0;
		let hi = 1;
		t = x;
		while (hi - lo > 1e-4) {
			if (sampleX(t) < x) lo = t;
			else hi = t;
			t = (lo + hi) / 2;
		}
		return sampleY(t);
	};
}

/** --motion-ease-standard (global.css): the sidebar toggle's curve. */
export const easeStandard = cubicBezier(0.4, 0, 0.2, 1);
