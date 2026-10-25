// The one tab row whose name is being edited by a double-click on its title, and the saved tab
// open in its editor from the context menu's Edit...

import { on } from "../lib/bridge";

let renamingTabId = $state<string | null>(null);
let editingTab = $state<{ id: string; homeURL: string } | null>(null);

export function getRenamingTabId(): string | null {
	return renamingTabId;
}

export function setRenamingTabId(id: string | null): void {
	renamingTabId = id;
}

export function getEditingTab(): { id: string; homeURL: string } | null {
	return editingTab;
}

export function closeTabEditor(): void {
	editingTab = null;
}

export function initTabRenameStore(): void {
	on("beginTabEdit", (data) => {
		editingTab = { id: data.id, homeURL: data.homeURL };
	});
}
