import { on } from "../lib/bridge";
import { tabShareActions } from "../lib/bridge/actions";

interface TabShareRequest {
	requestId: string;
	origin: string;
	shareableTabIds: Set<string>;
	allowsSystem: boolean;
}

let _request = $state<TabShareRequest | null>(null);

export function initTabShareStore(): void {
	on("tabSharePickerRequested", (data) => {
		// One picker at a time: a request arriving while another is shown is
		// cancelled immediately so its page promise settles.
		if (_request) {
			tabShareActions.resolve({ requestId: data.requestId, choice: "cancel" });
			return;
		}
		_request = {
			requestId: data.requestId,
			origin: data.origin,
			shareableTabIds: new Set(data.shareableTabIds),
			allowsSystem: data.allowsSystem !== false,
		};
	});
	on("tabSharePickerDismissed", (data) => {
		if (_request?.requestId === data.requestId) _request = null;
	});
}

export function getTabShareRequest(): TabShareRequest | null {
	return _request;
}

export function resolveTabShare(
	choice: "tab" | "system" | "cancel",
	tabId?: string,
): void {
	if (!_request) return;
	tabShareActions.resolve({
		requestId: _request.requestId,
		choice,
		...(choice === "tab" && tabId ? { tabId } : {}),
	});
	_request = null;
}
