import { on } from "../lib/bridge";

type LockPanel = {
	folderId: string;
	kind: "unlock" | "setup";
	failed: boolean;
	biometricsAvailable: boolean;
};

let _panel = $state<LockPanel | null>(null);

export function getLockPanel(): LockPanel | null {
	return _panel;
}

export function openLockPanel(folderId: string, kind: "unlock" | "setup", biometricsAvailable = false): void {
	_panel = { folderId, kind, failed: false, biometricsAvailable };
}

export function closeLockPanel(): void {
	_panel = null;
}

export function initFolderLockStore(): void {
	on("beginFolderUnlock", (data) => openLockPanel(data.id, "unlock"));
	on("beginFolderLockSetup", (data) => openLockPanel(data.id, "setup", data.biometricsAvailable));
	on("folderUnlockFailed", (data) => {
		if (_panel?.folderId === data.id) _panel = { ..._panel, failed: true };
	});
}
