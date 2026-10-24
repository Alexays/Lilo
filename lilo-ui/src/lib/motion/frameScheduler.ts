/**
 * At most one callback per animation frame, the latest scheduled; `cancel` reports whether one was pending.
 * A fn may re-schedule itself from inside the frame callback.
 */
export function createFrameScheduler(): {
	schedule: (fn: () => void) => void;
	cancel: () => boolean;
} {
	let frame: number | null = null;
	let pending: (() => void) | null = null;

	return {
		schedule(fn: () => void): void {
			pending = fn;
			if (frame !== null) return;
			frame = requestAnimationFrame(() => {
				frame = null;
				const run = pending;
				pending = null;
				run?.();
			});
		},
		cancel(): boolean {
			const wasPending = pending !== null;
			if (frame !== null) cancelAnimationFrame(frame);
			frame = null;
			pending = null;
			return wasPending;
		},
	};
}
