export type ToastVariant =
	| "copied"
	| "installed"
	| "failed"
	| "zoom"
	| "recovered";

export interface URLVisual {
	key: string;
	host: string;
	displayHost: string;
	hostIdentity: string;
	path: string;
	isSecure: boolean;
	/** Plain http, or https the engine reports as not secure (certificate exception, mixed content). */
	insecure: boolean;
	isPlaceholder: boolean;
	isFeedback?: boolean;
	feedbackVariant?: ToastVariant;
}
