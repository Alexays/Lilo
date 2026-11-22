import { mount } from "svelte";
import { littleActions } from "../lib/bridge/actions";
import { initCommandBarStore, restrictCommandBar } from "../stores/commandBar.svelte";
import { initSearchEngineStore } from "../stores/searchEngines";
import { initSettingsStore } from "../stores/settings.svelte";
import LittleApp from "./LittleApp.svelte";
import { initLittleStore } from "./little.svelte";

/** Mounts a Little window's interface: only the stores its command bar and strip read. */
export function mountLittle(target: HTMLElement) {
	initLittleStore();
	initSettingsStore();
	initSearchEngineStore();
	initCommandBarStore();
	// No tabs, Spaces or actions here: a row opens, copies or goes.
	restrictCommandBar(["newTab", "copy", "remove"]);
	const app = mount(LittleApp, { target });
	littleActions.ready();
	return app;
}
