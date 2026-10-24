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
	isPlaceholder: boolean;
	isFeedback?: boolean;
	feedbackVariant?: ToastVariant;
}
