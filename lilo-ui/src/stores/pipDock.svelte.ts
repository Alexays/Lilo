import { on } from "../lib/bridge";

let _active = $state(false);
let _title = $state("");
let _aspectRatio = $state(1.6);

// The native side docks a scaled in-call tab over the slot this store drives; the slot's
// interactive zone rect is how the native view knows where to sit.
export function initPipDockStore(): void {
	on("pipDockChanged", (data) => {
		_active = data.active;
		_title = data.title ?? "";
		_aspectRatio = data.aspectRatio ?? 1.6;
	});
}

export function getPipDockAspectRatio(): number {
	return _aspectRatio;
}

export function isPipDockActive(): boolean {
	return _active;
}

export function getPipDockTitle(): string {
	return _title;
}
