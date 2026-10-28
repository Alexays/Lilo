import { on, postMessage } from "../lib/bridge";
import type { BridgeEventPayloadMap } from "../lib/bridge/protocol";

export type WhatsNewRequest = BridgeEventPayloadMap["openWhatsNew"];
let request = $state.raw<WhatsNewRequest | null>(null);

// Keep these callbacks with the deferred store, outside the first-frame bridge actions.
export function requestAutomaticWhatsNew(): void { postMessage("requestWhatsNew"); }
export function acknowledgeWhatsNew(version: string): void { postMessage("whatsNewPresented", { version }); }

export function initWhatsNewStore(): void {
	on("openWhatsNew", (data) => { request ??= data; });
}

export function getWhatsNewRequest(): WhatsNewRequest | null { return request; }

export function closeWhatsNew(): void {
	if (!request) return;
	request = null;
	postMessage("dismissWhatsNew");
}
