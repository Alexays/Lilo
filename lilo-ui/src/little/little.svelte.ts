import { on, type BridgeLittleState } from "../lib/bridge";

const initial: BridgeLittleState = {
	mode: "start",
	url: "",
	loading: false,
	space: { id: "", name: "", icon: "", color: "" },
	otherSpaces: [],
	leadingInset: 78,
};

let state = $state<BridgeLittleState>(initial);

export const getLittleState = (): BridgeLittleState => state;

/** Follows the host's state for this window: it sends the whole of it on every change. */
export function initLittleStore(): void {
	on("littleState", ({ event: _event, ...next }) => {
		state = next;
	});
}
