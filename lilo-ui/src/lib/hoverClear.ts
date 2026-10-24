// One lazily registered set of window/document listeners fans the hover clear out to every row, not one per row.
// Window focus comes from the native `windowFocusChanged`: the DOM `blur` also fires on every tab activation.

type HoverClearSubscriber = {
	onClear: () => void;
	reactToDndActiveChange: boolean;
};

const subscribers = new Set<HoverClearSubscriber>();
let listenersActive = false;

/**
 * Called on the native window losing key focus (`windowFocusChanged`), never on a DOM `blur`, which also fires on
 * the chrome-to-content first-responder handoff of a plain tab activation.
 */
export function clearAllHover(): void {
	for (const subscriber of subscribers) subscriber.onClear();
}

function handleVisibilityChange(): void {
	if (document.visibilityState !== "visible") clearAllHover();
}

function handleDndActiveChange(): void {
	for (const subscriber of subscribers) {
		if (subscriber.reactToDndActiveChange) subscriber.onClear();
	}
}

function ensureListeners(): void {
	if (listenersActive) return;
	listenersActive = true;
	document.addEventListener("visibilitychange", handleVisibilityChange);
	document.addEventListener("lilo-sidebar-dnd-active-change", handleDndActiveChange);
}

function teardownListeners(): void {
	if (!listenersActive) return;
	listenersActive = false;
	document.removeEventListener("visibilitychange", handleVisibilityChange);
	document.removeEventListener("lilo-sidebar-dnd-active-change", handleDndActiveChange);
}

/**
 * `onClear` fires on window focus loss, a hidden document, and (with `reactToDndActiveChange`) a sidebar drag
 * start. Returns an unsubscribe function to call on unmount.
 */
export function subscribeHoverClear(
	onClear: () => void,
	options: { reactToDndActiveChange?: boolean } = {},
): () => void {
	const subscriber: HoverClearSubscriber = {
		onClear,
		reactToDndActiveChange: options.reactToDndActiveChange ?? false,
	};
	subscribers.add(subscriber);
	ensureListeners();
	return () => {
		subscribers.delete(subscriber);
		if (subscribers.size === 0) teardownListeners();
	};
}
