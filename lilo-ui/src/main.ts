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

// A Little window runs the same bundle with only its own screen: no sidebar, tabs or Spaces behind it.
const isLittleWindow = new URLSearchParams(location.search).has("little");
if (!isLittleWindow) initChromeStores(takeBootstrapInitialState());

const target = document.getElementById("app");

if (!target) {
	throw new Error("Missing #app mount target");
}

if (localeLoaded) await localeLoaded;

const app = isLittleWindow ? (await import("./little/mountLittle")).mountLittle(target) : mount(App, { target });
if (!isLittleWindow) {
	chromeActions.startupMark("chromeMounted");

	// After the deferred stores' microtask and the mount's effect flush (onMount listeners): replayed
	// synchronously here, events queued before the bundle loaded would find no listener and be lost.
	queueMicrotask(consumeBootstrapEvents);
}

export default app;
