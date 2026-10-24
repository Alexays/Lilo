// The tab a selection-travel ghost is currently flying toward. While set, that row holds
// back its own active highlight (TabItem `.travel-hold`) so the ghost is the only visible
// selection; SelectionIndicator clears it on landing or cancellation.
let _targetTabId = $state<string | null>(null);

export function getSelectionTravelTarget(): string | null {
	return _targetTabId;
}

export function setSelectionTravelTarget(tabId: string | null): void {
	_targetTabId = tabId;
}
