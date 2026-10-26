<script lang="ts">
  import { onMount } from "svelte";
  import { demoFeatures } from "../lib/i18n.ts";
  import type { DemoFeatureId } from "../lib/i18n.ts";
  import { demoCopy } from "./world.ts";
  import type { DemoLocale } from "./world.ts";

  interface Props {
    locale: DemoLocale;
    onselect: (id: DemoFeatureId) => void;
    onclose: () => void;
  }

  let { locale, onselect, onclose }: Props = $props();
  let query = $state("");
  let selected = $state<DemoFeatureId>("spaces");
  let dialog: HTMLDialogElement | undefined = $state();
  const text = $derived(demoCopy(locale));
  const features = $derived(demoFeatures[locale].filter((feature) => `${feature.title} ${feature.description}`.toLocaleLowerCase().includes(query.toLocaleLowerCase())));
  const feature = $derived(features.find((item) => item.id === selected) ?? features[0]);

  onMount(() => {
    dialog?.showModal();
    dialog?.querySelector("input")?.focus();

    return () => dialog?.close();
  });
</script>

  <dialog class="explore-window" bind:this={dialog} aria-label={text.explore} oncancel={(event) => { event.preventDefault(); onclose(); }} onkeydown={(event) => { if (event.key === "Escape") { event.preventDefault(); onclose(); } }}>
    <header><h2>{text.explore}</h2><button class="close" type="button" aria-label={text.previewClose} onclick={onclose}>×</button></header>
    <div class="explore-body">
      <nav aria-label={text.explore}><input type="search" aria-label={text.exploreSearch} placeholder={text.exploreSearch} bind:value={query} />
        <div class="feature-list">{#each features as item (item.id)}<button type="button" class:selected={feature?.id === item.id} aria-pressed={feature?.id === item.id} onclick={() => { selected = item.id; }}><span>{item.title}</span>{#if item.mac}<small>macOS</small>{/if}</button>{/each}</div>
      </nav>
      <div class="feature-detail">{#if feature}<span class="feature-index" aria-hidden="true">✳</span>{#if feature.mac}<span class="platform">{text.exploreMac}</span>{/if}<h3>{feature.title}</h3><p>{feature.description}</p>{#if feature.mac}<p class="platform-note">{text.exploreMacNote}</p>{/if}<button class="try-feature" type="button" onclick={() => onselect(feature.id)}>{feature.mac ? text.exploreSettings : text.exploreOpen}<span aria-hidden="true">↗</span></button>{:else}<p>{text.exploreEmpty}</p>{/if}</div>
    </div>
  </dialog>

<style>
  .explore-window { display: flex; flex-direction: column; width: min(760px, calc(100% - 60px)); height: min(570px, calc(100% - 60px)); padding: 0; box-sizing: border-box; border: 1px solid var(--border); border-radius: 12px; background: var(--bg-primary); color: var(--text-primary); font: 12px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; box-shadow: 0 20px 70px #00000030; overflow: hidden; outline: none; }
  .explore-window:not([open]) { display: none; }
  .explore-window::backdrop { background: #00000022; }
  header { display: flex; align-items: center; justify-content: space-between; flex: none; padding: 14px 18px; border-bottom: 1px solid var(--border); }
  h2 { margin: 0; font-size: 14px; font-weight: 600; }
  button { color: inherit; font: inherit; cursor: pointer; }
  .close { width: 24px; height: 24px; padding: 0; border: 0; border-radius: 50%; background: var(--bg-hover); color: var(--text-secondary); font-size: 18px; }
  .explore-body { display: flex; min-height: 0; flex: 1; }
  nav { display: flex; flex-direction: column; gap: 10px; width: 245px; flex: none; padding: 14px 10px 10px; box-sizing: border-box; border-right: 1px solid var(--border); background: var(--bg-hover); }
  input { width: 100%; flex: none; box-sizing: border-box; border: 1px solid var(--border); border-radius: 7px; padding: 7px 9px; background: var(--bg-primary); color: var(--text-primary); font: inherit; font-size: 11px; }
  .feature-list { min-height: 0; overflow: auto; }
  .feature-list button { display: flex; align-items: center; justify-content: space-between; gap: 6px; width: 100%; padding: 8px 9px; border: 0; border-radius: 6px; background: none; text-align: left; font-size: 11px; }
  .feature-list button:hover { background: var(--bg-active); }
  .feature-list button.selected { background: var(--bg-selected); font-weight: 600; }
  small { flex: none; font-size: 8px; color: var(--text-muted); font-weight: 400; }
  .feature-detail { flex: 1; min-width: 0; overflow: auto; padding: 30px; }
  .feature-index { display: grid; place-items: center; width: 56px; height: 56px; margin-bottom: 24px; border-radius: 15px; background: var(--bg-hover); color: #9984c8; font-size: 40px; }
  h3 { font-size: 23px; line-height: 1.2; letter-spacing: -.5px; margin: 8px 0 15px; font-weight: 600; }
  p { margin: 0 0 18px; color: var(--text-secondary); line-height: 1.7; }
  .platform { color: var(--text-muted); font-size: 10px; }
  .platform-note { font-size: 11px; color: var(--text-muted); }
  .try-feature { display: inline-flex; align-items: center; gap: 22px; padding: 8px 12px; border: 1px solid var(--border); border-radius: 7px; background: var(--text-primary); color: var(--bg-primary); font-size: 11px; font-weight: 600; }
  button:focus-visible, input:focus-visible { outline: var(--focus-outline); outline-offset: 2px; }
</style>
