const URL_PROGRESS_FLOOR = 0.06;
const URL_PROGRESS_COMPLETE_CAP = 0.985;
export const URL_PROGRESS_STALLED_DELAY_MS = 1_700;
export const URL_PROGRESS_TRICKLE_CAP_MS = 30_000;

function normalizeReportedProgress(rawProgress: number): number {
	const progress = Math.max(0, Math.min(1, rawProgress));
	if (progress <= 0.015) return URL_PROGRESS_FLOOR;
	if (progress >= URL_PROGRESS_COMPLETE_CAP) return URL_PROGRESS_COMPLETE_CAP;
	return progress;
}

export function computeDisplayedLoadingProgress(
	rawProgress: number,
	currentDisplayedProgress: number,
): number {
	return Math.max(currentDisplayedProgress, normalizeReportedProgress(rawProgress));
}

export function nextTrickleProgress(
	currentDisplayedProgress: number,
	reportedProgress: number,
): number {
	const floor = Math.max(currentDisplayedProgress, normalizeReportedProgress(reportedProgress));
	const cap = floor < 0.18 ? 0.32 : floor < 0.58 ? 0.78 : 0.9;
	const step = floor < 0.18 ? 0.115 : floor < 0.58 ? 0.06 : 0.02;
	return Math.max(floor, Math.min(cap, Number((floor + step).toFixed(3))));
}

export function progressMoved(nextProgress: number, lastProgress: number): boolean {
	return Math.abs(nextProgress - lastProgress) > 0.004;
}
