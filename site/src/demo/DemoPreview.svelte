<script lang="ts">
  import { onMount, untrack } from "svelte";
  import { LINE_ICONS } from "../../../lilo-ui/src/components/commandbar/commandBarIcons";
  import SettingsIcon from "../../../lilo-ui/src/components/settings/SettingsIcon.svelte";
  import SiteFavicon from "../../../lilo-ui/src/components/ui/SiteFavicon.svelte";
  import type { DemoHost } from "./host.ts";
  import { demoCopy, makeTab, pageNotes, pageProjects } from "./world.ts";
  import type { DemoLocale } from "./world.ts";
  import DemoPage from "./DemoPage.svelte";

  interface Props {
    host: DemoHost;
    locale: DemoLocale;
    mode: "peek" | "little";
    url: string;
    onclose: () => void;
    onpreview: (mode: "peek" | "little", url: string) => void;
  }

  let { host, locale, mode, url, onclose, onpreview }: Props = $props();
  const text = $derived(demoCopy(locale));
  let tab = $state(untrack(() => makeTab(crypto.randomUUID(), host.snapshot().activeSpaceId, "Lilo", url)));
  let dialog: HTMLDialogElement | undefined = $state();
  const navigate = (address: string) => { if (/^https?:\/\//iu.test(address)) { tab = { ...tab, url: new URL(address).href }; } };

  export const expand = () => {
    host.dispatch("createTab", { url: tab.url });
    const id = host.snapshot().activeTabId;
    const note = pageNotes.get(tab.id);
    const project = pageProjects.get(tab.id);

    if (note !== undefined) { pageNotes.set(id, note); }

    if (project) { pageProjects.set(id, project); }

    onclose();
  };

  onMount(() => {
    dialog?.showModal();

    return () => { dialog?.close(); pageNotes.delete(tab.id); pageProjects.delete(tab.id); };
  });
</script>

<dialog class="preview-window" class:little={mode === "little"} bind:this={dialog} aria-label={mode === "peek" ? "Peek" : text.previewLittle} oncancel={(event) => { event.preventDefault(); onclose(); }}>
  <header><button class="close" type="button" aria-label={text.previewClose} onclick={onclose}><svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><path d={LINE_ICONS.stop} /></svg></button><span class="preview-address"><SiteFavicon src={host.faviconFor(tab.url)} url={tab.url} size={14} />{new URL(tab.url).hostname}</span><button class="expand" type="button" aria-label={text.previewExpand} onclick={expand}><SettingsIcon name="arrowOutOfBox" /></button></header>
  <div class="preview-page"><DemoPage {tab} {host} {locale} onnavigate={navigate} {onpreview} onpreviewclose={onclose} /></div>
</dialog>

<style>
  .preview-window { display: flex; flex-direction: column; width: min(820px, calc(100% - 100px)); height: calc(100% - 65px); margin: auto; padding: 0; box-sizing: border-box; border: 1px solid var(--border); border-radius: 12px; background: var(--bg-primary); color: var(--text-primary); box-shadow: 0 25px 80px #00000044; overflow: hidden; }
  .preview-window:not([open]) { display: none; }
  .preview-window::backdrop { background: #00000028; }
  .preview-window.little { width: 560px; height: min(480px, calc(100% - 90px)); }
  header { display: flex; align-items: center; justify-content: space-between; flex: none; gap: 16px; height: 40px; padding: 0 12px; background: var(--bg-elevated); border-bottom: 1px solid var(--border); font: 11px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; }
  header > button { display: grid; place-items: center; flex: none; width: 24px; height: 24px; padding: 0; border: 0; border-radius: 6px; background: var(--bg-hover); color: var(--text-secondary); cursor: pointer; }
  .preview-address { display: flex; align-items: center; gap: 6px; min-width: 0; color: var(--text-secondary); }
  .preview-page { flex: 1; min-height: 0; }
  button:focus-visible { outline: var(--focus-outline); outline-offset: 3px; }
</style>
