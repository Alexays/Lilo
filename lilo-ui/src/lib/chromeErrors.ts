import { chromeActions } from "./bridge/actions";

let lastMessage = "";

/** Logs an uncaught chrome error natively; a region that keeps throwing logs it once. */
export function reportChromeError(error: unknown): void {
	const message = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
	if (message === lastMessage) return;
	lastMessage = message;
	chromeActions.reportChromeError({ message, stack: error instanceof Error ? error.stack : undefined });
}
