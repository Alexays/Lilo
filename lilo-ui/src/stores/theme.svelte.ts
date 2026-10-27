// The theme the sidebar was last derived for: folder colors are guarded against it.

import { deriveFolderColorVariables } from "../lib/sidebarTheme";

export const FOLDER_COLORS = ["#5b7cff", "#5fd79a", "#ffcc57", "#ff8a5b", "#f06aa6", "#9b7cff", "#4ecdc4", "#8a9ba8"];

let context = $state({ sidebarBg: "#e2daf1", prefersDark: false });
// Per folder color for the current theme; a theme change starts it over.
let cache = new Map<string, string>();

export function setThemeContext(sidebarBg: string, prefersDark: boolean): void {
	if (context.sidebarBg === sidebarBg && context.prefersDark === prefersDark) return;
	cache = new Map();
	context = { sidebarBg, prefersDark };
}

export function themeSidebarBackground(): string {
	return context.sidebarBg;
}

/** The inline style giving a folder row its guarded color and open background. */
export function folderColorStyle(color: string | undefined): string {
	const { sidebarBg, prefersDark } = context;
	const key = color ?? "";
	const cached = cache.get(key);
	if (cached) return cached;
	const vars = deriveFolderColorVariables(key, sidebarBg, prefersDark);
	const style = `--folder-accent: ${vars["--folder-accent"]}; --folder-open-bg: ${vars["--folder-open-bg"]};`;
	cache.set(key, style);
	return style;
}
