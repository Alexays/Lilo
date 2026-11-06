import { mount } from "svelte";
import App from "./App.svelte";
import {
	consumeBootstrapEvents,
	takeBootstrapInitialState,
} from "./lib/bridge";
import { chromeActions } from "./lib/bridge/actions";
import { reportChromeError } from "./lib/chromeErrors";
import { setLocale } from "./lib/i18n/state.svelte";
import { resolveLocale } from "./lib/i18n/translate";
import { initChromeStores } from "./stores/init";
import "./styles/global.css";
import "./styles/utilities.css";

addEventListener("error", (event) => reportChromeError(event.error ?? event.message));
addEventListener("unhandledrejection", (event) => reportChromeError(event.reason));

// A non-English catalog loads before mounting so the first paint never flashes English. Its fetch
// starts here so it overlaps the store setup instead of following it.
const locale = resolveLocale(document.documentElement.dataset.locale ?? navigator.language);
const localeLoaded = locale === "en" ? null : setLocale(locale);

const initialState = takeBootstrapInitialState();
initChromeStores(initialState);

const target = document.getElementById("app");

if (!target) {
	throw new Error("Missing #app mount target");
}

if (localeLoaded) await localeLoaded;

const app = mount(App, { target });
chromeActions.startupMark("chromeMounted");

// After the deferred stores' microtask and the mount's effect flush (onMount listeners): replayed
// synchronously here, events queued before the bundle loaded would find no listener and be lost.
queueMicrotask(consumeBootstrapEvents);

export default app;
