export function formatEta(seconds: number): string {
	if (seconds < 60) return `${Math.ceil(seconds)}s`;
	if (seconds < 3600) return `${Math.ceil(seconds / 60)}m`;
	return `${Math.ceil(seconds / 3600)}h`;
}

export function progress(dl: { totalBytes: number; bytesReceived: number }): number {
	if (dl.totalBytes <= 0) return 0;
	return Math.min(100, (dl.bytesReceived / dl.totalBytes) * 100);
}
