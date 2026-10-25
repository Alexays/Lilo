<script lang="ts">
  import { untrack } from "svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import { tabActions } from "../../lib/bridge/actions";
  import { DEFAULT_TAB_TITLE } from "../../lib/bridge/defaults";
  import { fallbackTabTitle } from "../../lib/bridge/coerceHelpers";
  import { parseInput } from "../../lib/inputParser";
  import { t } from "../../lib/i18n/state.svelte";
  import type { TabState } from "../../stores/tabs.svelte";

  interface Props {
    tab: TabState;
    homeURL: string;
    onclose: () => void;
  }

  let { tab, homeURL, onclose }: Props = $props();

  // The name the sidebar shows for the tab: its own, its home page's, or the page's.
  const shownName = untrack(() =>
    tab.customTitle || tab.homeTitle || (tab.title && tab.title !== DEFAULT_TAB_TITLE ? tab.title : fallbackTabTitle(tab.url)),
  );
  let draftName = $state(shownName);
  let draftURL = $state(untrack(() => homeURL));
  const parsed = $derived(parseInput(draftURL));
  const nextURL = $derived(parsed.type === "url" ? parsed.url : null);

  let card: HTMLDivElement | undefined = $state();
  let nameInput: HTMLInputElement | undefined = $state();

  $effect(() => {
    nameInput?.focus();
    nameInput?.select();
  });

  $effect(() => {
    const dismiss = (event: PointerEvent): void => {
      if (event.target instanceof Node && !card?.contains(event.target)) onclose();
    };
    window.addEventListener("pointerdown", dismiss, true);
    return () => window.removeEventListener("pointerdown", dismiss, true);
  });

  function save(): void {
    if (!nextURL) return;
    const name = draftName.trim();
    // Confirming the shown name keeps an unnamed tab following its page.
    if (name !== shownName) tabActions.rename(tab.id, name);
    if (nextURL !== homeURL) tabActions.setHomeURL(tab.id, nextURL);
    // Last: closing unmounts the editor, and its props stop resolving.
    onclose();
  }

  function handleKeydown(event: KeyboardEvent): void {
    if (event.key === "Enter") {
      event.preventDefault();
      save();
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      onclose();
    }
  }
</script>

<!-- The row's drag starts on any pointerdown inside it: selecting text here must not move the tab. -->
<div
  bind:this={card}
  class="saved-tab-editor"
  role="dialog"
  tabindex="-1"
  aria-label={t("tabEditor.title")}
  onkeydown={handleKeydown}
  onpointerdown={(event) => event.stopPropagation()}
>
  <div class="editor-name">
    <SiteFavicon src={tab.faviconDataURL} title={tab.title} url={tab.url} size={16} radius={4} />
    <input
      bind:this={nameInput}
      bind:value={draftName}
      class="name-input"
      type="text"
      spellcheck="false"
      aria-label={t("tabItem.tabName")}
    />
  </div>
  <input
      class="url-input"
      bind:value={draftURL}
      type="text"
      spellcheck="false"
      aria-label={t("tabEditor.url")}
      aria-invalid={!nextURL}
    />
  {#if tab.url && tab.url !== nextURL}
    <div class="editor-row">
      <UiButton variant="ghost" onclick={() => (draftURL = tab.url)}>{t("tabEditor.useCurrentPage")}</UiButton>
    </div>
  {/if}
  <div class="editor-row editor-actions">
    <UiButton variant="ghost" onclick={onclose}>{t("common.cancel")}</UiButton>
    <UiButton variant="primary" disabled={!nextURL} onclick={save}>{t("common.save")}</UiButton>
  </div>
</div>

<style>
  .saved-tab-editor {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-block: 2px 6px;
    padding: 8px;
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--bg-primary) 62%, transparent);
    box-shadow: 0 6px 18px color-mix(in srgb, var(--accent) 12%, transparent);
  }

  .editor-name {
    display: flex;
    align-items: center;
    gap: 2px;
    padding-left: 2px;
  }

  .name-input:focus {
    background: color-mix(in srgb, var(--text-primary) 5%, transparent);
  }

  .name-input {
    flex: 1;
    min-width: 0;
    height: 26px;
    padding: 0 6px;
    border: none;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
    outline: none;
  }

  .url-input {
    height: 28px;
    padding: 0 8px;
    border: none;
    border-radius: var(--radius-sm);
    background: color-mix(in srgb, var(--text-primary) 5%, transparent);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    outline: none;
  }

  .editor-row {
    display: flex;
    gap: 4px;
  }

  .editor-actions {
    justify-content: flex-end;
  }
</style>
