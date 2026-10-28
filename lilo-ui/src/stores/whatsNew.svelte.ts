import { on } from "../lib/bridge";
import { whatsNewActions } from "../lib/bridge/actions";
import type { BridgeEventPayloadMap } from "../lib/bridge/protocol";

export type WhatsNewRequest = BridgeEventPayloadMap["openWhatsNew"];
let request = $state.raw<WhatsNewRequest | null>(null);

export function initWhatsNewStore(): void {
	on("openWhatsNew", (data) => { request ??= data; });
}

export function getWhatsNewRequest(): WhatsNewRequest | null { return request; }

export function closeWhatsNew(): void {
	if (!request) return;
	request = null;
	whatsNewActions.dismiss();
}
