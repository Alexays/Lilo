// One polite live region for the whole chrome. A region inserted with its text already in it is
// often not read, so it is created empty, once, and only its text changes.
let region: HTMLElement | null = null;

export function announce(message: string): void {
	if (typeof document === "undefined" || !message) return;
	if (!region) {
		region = document.createElement("div");
		region.className = "live-announcer";
		region.setAttribute("role", "status");
		region.setAttribute("aria-live", "polite");
		region.style.cssText = "position:fixed;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap;";
		document.body.append(region);
		const fresh = region;
		// Give the screen reader a beat to register the empty region before it speaks.
		setTimeout(() => (fresh.textContent = message), 100);
		return;
	}
	// The same message twice in a row still has to change the text to be spoken again.
	region.textContent = region.textContent === message ? `${message}\u00a0` : message;
}
