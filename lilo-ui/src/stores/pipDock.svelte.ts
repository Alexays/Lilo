import { on } from "../lib/bridge";

let _active = $state(false);
let _title = $state("");

// The native side docks a scaled in-call tab over the slot this store drives; the slot's
// interactive zone rect is how the native view knows where to sit.
export function initPipDockStore(): void {
	on("pipDockChanged", (data) => {
		_active = data.active;
		_title = data.title ?? "";
	});
}

export function isPipDockActive(): boolean {
	return _active;
}

export function getPipDockTitle(): string {
	return _title;
}
