interface TabCloseState {
	isClosed: boolean;
	isPinned: boolean;
	isBookmarked: boolean;
}

type TabCloseIntent = "close" | "unpin" | "unbookmark";

export function resolveTabCloseIntent(tab: TabCloseState): TabCloseIntent {
	if (tab.isClosed && tab.isPinned) {
		return "unpin";
	}

	if (tab.isClosed && tab.isBookmarked) {
		return "unbookmark";
	}

	return "close";
}

