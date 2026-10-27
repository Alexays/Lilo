import { on } from "../lib/bridge";
import type { SpaceColorMode } from "../lib/bridge/protocol";
import {
	DEFAULT_ACCENT_COLOR,
	DEFAULT_SPACE_ICON,
	DEFAULT_SPACE_NAME,
} from "../lib/bridge/defaults";
import { getActiveProfileId } from "./profiles.svelte";
import { getActiveSpace, getSpaces } from "./spaces.svelte";

export type SettingsSectionId =
	| "general"
	| "appearance"
	| "tabs"
	| "privacy"
	| "extensions"
	| "terminal"
	| "agents"
	| "advanced";

export type DesignSystemSectionId =
	| "foundations"
	| "layout"
	| "sidebar"
	| "panels"
	| "controls"
	| "patterns";

type ShellKind = "settings" | "designSystem";

const _shell = $state<{
	activeSurface: ShellKind | null;
	sections: {
		settings: SettingsSectionId;
		designSystem: DesignSystemSectionId;
	};
	// A drill-in page inside the settings section ("engines", "sites", "site:<key>", "extension:<id>").
	settingsSubpage: string | null;
	settingsQuery: string;
	// The setting a search result led to: its row scrolls into view and flashes once.
	settingsHighlight: string | null;
}>({
	activeSurface: null,
	sections: { settings: "general", designSystem: "foundations" },
	settingsSubpage: null,
	settingsQuery: "",
	settingsHighlight: null,
});

type PanelKind =
	| "editor"
	| "downloads"
	| "diagnostics"
	| "processes"
	| "screenshot"
	| null;
type EditorMode = "edit" | "add";

interface EditorState {
	open: boolean;
	mode: EditorMode;
	name: string;
	icon: string;
	color: string;
	colorMode: SpaceColorMode;
	profileId: string;
	spaceId: string;
	archiveAfterHours: number;
}

type EditorFields = Omit<EditorState, "open">;

interface PanelsState {
	activePanel: PanelKind;
	editor: EditorFields;
}

const EMPTY_EDITOR_STATE: EditorFields = {
	mode: "edit",
	name: "",
	icon: "",
	color: "",
	colorMode: "fixed",
	profileId: "",
	spaceId: "",
	archiveAfterHours: 12,
};

const _panels = $state<PanelsState>({
	activePanel: null,
	editor: { ...EMPTY_EDITOR_STATE },
});

function openShell(kind: ShellKind): void {
	_panels.activePanel = null;
	_shell.activeSurface = kind;
}

function openPanel(panel: Exclude<PanelKind, null>): void {
	_shell.activeSurface = null;
	_panels.activePanel = panel;
}

function openEditorPanel(editor: EditorFields): void {
	_panels.editor = editor;
	openPanel("editor");
}

function isPanelOpen(panel: Exclude<PanelKind, null>): boolean {
	return _panels.activePanel === panel;
}

export function initPanelsStore(): void {
	on("openSettings", () => {
		openSettings();
	});

	on("openClearBrowsingData", () => {
		openSettings("privacy");
		openSettingsSubpage("privacy", "browsingData");
	});

	on("openDesignSystem", () => {
		openDesignSystem();
	});

	on("openDiagnostics", () => {
		openDiagnostics();
	});

	on("openProcessManager", () => {
		openProcessManager();
	});

	on("openDownloads", () => {
		openDownloadsPanel();
	});

	on("openExtensions", () => {
		openSettings("extensions");
	});

	on("openConfig", () => {
		openSettings("advanced");
	});

	on("openShortcuts", () => {
		openSettings("general");
		openSettingsSubpage("general", "shortcuts");
	});

	on("openSpaceEditor", (data) => {
		openEditor(typeof data.id === "string" ? data.id : undefined);
	});

	on("openAddSpaceEditor", () => {
		openAddEditor();
	});

	on("spaceDeleted", (data) => {
		if (
			isPanelOpen("editor") &&
			_panels.editor.mode === "edit" &&
			_panels.editor.spaceId === data.id
		) {
			updateEditorState({ spaceId: "" });
			closeActivePanel();
		}
	});
}

export function getActivePanel(): PanelKind {
	return _panels.activePanel;
}

export function hasActivePanel(): boolean {
	return _panels.activePanel !== null;
}

export function closeActivePanel(): void {
	_panels.activePanel = null;
}

export function isEditorOpen(): boolean {
	return isPanelOpen("editor");
}

export function openEditor(id?: string): void {
	const space = id ? getSpaces().find((s) => s.id === id) : getActiveSpace();
	if (!space) return;

	openEditorPanel({
		mode: "edit",
		spaceId: space.id,
		name: space.name,
		icon: space.icon,
		color: space.color,
		colorMode: space.colorMode ?? "fixed",
		profileId: space.profileId,
		archiveAfterHours: space.archiveAfterHours ?? 12,
	});
}

export function openAddEditor(): void {
	openEditorPanel({
		mode: "add",
		spaceId: "",
		name: DEFAULT_SPACE_NAME,
		icon: DEFAULT_SPACE_ICON,
		color: DEFAULT_ACCENT_COLOR,
		colorMode: "fixed",
		profileId: getActiveProfileId() || getActiveSpace()?.profileId || "",
		archiveAfterHours: 12,
	});
}

export function closeEditor(): void {
	if (isPanelOpen("editor")) {
		closeActivePanel();
	}
}

export function editorState(): EditorState {
	return {
		open: isEditorOpen(),
		..._panels.editor,
	};
}

export function updateEditorState(patch: Partial<EditorFields>): void {
	_panels.editor = { ..._panels.editor, ...patch };
}

// Opening a shell lands on the requested section (the default one otherwise), matching
// close-then-reopen: no leftover drill-in page or search.
export function openSettings(section: SettingsSectionId = "general"): void {
	setActiveSettingsSection(section);
	openShell("settings");
}

export function openDesignSystem(): void {
	_shell.sections.designSystem = "foundations";
	openShell("designSystem");
}

export const isDiagnosticsVisible = (): boolean => isPanelOpen("diagnostics");
export const openDiagnostics = (): void => openPanel("diagnostics");

export const isProcessManagerVisible = (): boolean => isPanelOpen("processes");
export const openProcessManager = (): void => openPanel("processes");

export const isDownloadsVisible = (): boolean => isPanelOpen("downloads");
export const openDownloadsPanel = (): void => openPanel("downloads");

export const openScreenshotPanel = (): void => openPanel("screenshot");

export function isSettingsShellOpen(): boolean {
	return _shell.activeSurface === "settings";
}

export function getSettingsShellSection(): SettingsSectionId {
	return _shell.sections.settings;
}

export function setActiveSettingsSection(section: SettingsSectionId): void {
	_shell.sections.settings = section;
	_shell.settingsSubpage = null;
	_shell.settingsQuery = "";
	_shell.settingsHighlight = null;
}

/** Leaves the search for the section holding `setting`, which then scrolls into view and flashes. */
export function revealSetting(section: SettingsSectionId, setting: string): void {
	setActiveSettingsSection(section);
	_shell.settingsHighlight = setting;
}

/** Hands the pending highlight to the row that shows it, once. */
export function takeSettingsHighlight(): string | null {
	const setting = _shell.settingsHighlight;
	_shell.settingsHighlight = null;
	return setting;
}

export function getSettingsSubpage(): string | null {
	return _shell.settingsSubpage;
}

export function openSettingsSubpage(section: SettingsSectionId, subpage: string): void {
	setActiveSettingsSection(section);
	_shell.settingsSubpage = subpage;
}

/** Back one level: a site's page returns to the site list, any other page to its section. */
export function closeSettingsSubpage(): void {
	_shell.settingsSubpage = _shell.settingsSubpage?.startsWith("site:") ? "sites" : null;
}

export function getSettingsQuery(): string {
	return _shell.settingsQuery;
}

export function setSettingsQuery(query: string): void {
	_shell.settingsQuery = query;
}

export function closeSettingsShell(): void {
	if (isSettingsShellOpen()) _shell.activeSurface = null;
}

export function isDesignSystemShellOpen(): boolean {
	return _shell.activeSurface === "designSystem";
}

export function getDesignSystemShellSection(): DesignSystemSectionId {
	return _shell.sections.designSystem;
}

export function setActiveDesignSystemSection(section: DesignSystemSectionId): void {
	_shell.sections.designSystem = section;
}

export function closeDesignSystemShell(): void {
	if (isDesignSystemShellOpen()) _shell.activeSurface = null;
}
