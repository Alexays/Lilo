import { mount } from "svelte";
import App from "./App.svelte";
import {
	consumeBootstrapEvents,
	takeBootstrapInitialState,
} from "./lib/bridge";
import { chromeActions } from "./lib/bridge/actions";
import { setLocale } from "./lib/i18n/state.svelte";
import { resolveLocale } from "./lib/i18n/translate";
import { initChromeStores } from "./stores/init";
import "./styles/global.css";
import "./styles/utilities.css";

const initialState = takeBootstrapInitialState();
initChromeStores(initialState);

const target = document.getElementById("app");

if (!target) {
	throw new Error("Missing #app mount target");
}

// A non-English catalog loads before mounting so the first paint never flashes English.
const locale = resolveLocale(navigator.language);
if (locale !== "en") await setLocale(locale);

const app = mount(App, { target });
chromeActions.startupMark("chromeMounted");

// After the deferred stores' microtask and the mount's effect flush (onMount listeners): replayed
// synchronously here, events queued before the bundle loaded would find no listener and be lost.
queueMicrotask(consumeBootstrapEvents);

export default app;
