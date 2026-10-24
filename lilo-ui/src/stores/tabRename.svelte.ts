// The one tab row whose name is being edited, from the context menu's Rename... or a double-click on its title.

import { on } from "../lib/bridge";

let renamingTabId = $state<string | null>(null);

export function getRenamingTabId(): string | null {
	return renamingTabId;
}

export function setRenamingTabId(id: string | null): void {
	renamingTabId = id;
}

export function initTabRenameStore(): void {
	on("beginTabRename", (data) => {
		renamingTabId = data.id;
	});
}
