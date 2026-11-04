<script lang="ts">
  import UiSearchField from "../ui/UiSearchField.svelte";
  import ExtensionRow from "./ExtensionRow.svelte";
  import type { ExtensionState } from "../../stores/extensions.svelte";
  import { filterExtensions } from "./extensionPanelModel";
  import { t } from "../../lib/i18n/state.svelte";

  interface Props {
    extensions: ExtensionState[];
    onopen: (id: string) => void;
    onmenu: (id: string, anchor: DOMRect) => void;
  }

  let { extensions, onopen, onmenu }: Props = $props();

  let query = $state("");
  const filtered = $derived(filterExtensions(extensions, query));
</script>

<div class="extension-list-pane">
  <UiSearchField
    placeholder={t("extensions.searchPlaceholder")}
    ariaLabel={t("extensions.searchPlaceholder")}
    value={query}
    onchange={(value) => (query = value)}
  />

  <div class="extension-body">
    {#if extensions.length === 0}
      <div class="empty-state">
        <p>{t("extensions.emptyTitle")}</p>
        <p class="hint">{t("extensions.emptyHint")}</p>
      </div>
    {:else if filtered.length === 0}
      <div class="empty-state">
        <p>{t("extensions.noResults")}</p>
      </div>
    {:else}
      <div class="extension-list">
        {#each filtered as ext (ext.id)}
          <ExtensionRow
            extension={ext}
            onopen={() => onopen(ext.id)}
            onmenu={(anchor) => onmenu(ext.id, anchor)}
          />
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .extension-list-pane {
    display: grid;
    gap: var(--space-12);
  }

  .extension-body {
    overflow: clip;
    border-radius: var(--radius-box);
    background: var(--group-box-bg);
    box-shadow: inset 0 0 0 1px var(--separator);
  }

  .empty-state {
    text-align: center;
    padding: 32px 16px;
    color: var(--text-muted);
  }

  .empty-state .hint {
    font-size: var(--font-size-sm);
    margin-top: 8px;
  }

  .extension-list > :global(* + *) {
    border-top: 1px solid var(--separator);
  }
</style>
