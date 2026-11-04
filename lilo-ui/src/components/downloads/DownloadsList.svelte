<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import DownloadRow from "./DownloadRow.svelte";
  import type { BridgeDownloadSnapshot } from "../../lib/bridge/protocol";
  import type { GroupedDownloads } from "./downloadsPanelModel";

  interface Props {
    groups: GroupedDownloads;
    hasAnyDownloads: boolean;
    hasFilteredResults: boolean;
    selectedId: number | null;
    onselect: (id: number) => void;
    onmenu: (download: BridgeDownloadSnapshot, anchor: DOMRect) => void;
  }

  let {
    groups,
    hasAnyDownloads,
    hasFilteredResults,
    selectedId,
    onselect,
    onmenu,
  }: Props = $props();
</script>

<div class="downloads-body">
  {#if !hasAnyDownloads}
    <div class="empty-state">
      <div class="empty-title">{t("downloadsPanel.emptyTitle")}</div>
      <div class="empty-copy">{t("downloadsPanel.emptyCopy")}</div>
    </div>
  {:else if !hasFilteredResults}
    <div class="empty-state">
      <div class="empty-title">{t("downloadsPanel.noResults")}</div>
    </div>
  {:else}
    {#if groups.active.length > 0}
      <section class="download-group" aria-label={t("downloadsPanel.activeGroupAriaLabel")}>
        <div class="download-group-title">{t("downloadsPanel.activeGroupTitle")}</div>
        {#each groups.active as dl (dl.id)}
          <DownloadRow
            download={dl}
            selected={selectedId === dl.id}
            onselect={() => onselect(dl.id)}
            onmenu={(anchor) => onmenu(dl, anchor)}
          />
        {/each}
      </section>
    {/if}

    {#each groups.history as group (group.key)}
      {@const label = group.labelKey ? t(group.labelKey) : group.label}
      <section class="download-group" aria-label={label}>
        <div class="download-group-title">{label}</div>
        {#each group.items as dl (dl.id)}
          <DownloadRow
            download={dl}
            selected={selectedId === dl.id}
            onselect={() => onselect(dl.id)}
            onmenu={(anchor) => onmenu(dl, anchor)}
          />
        {/each}
      </section>
    {/each}
  {/if}
</div>

<style>
  .empty-state {
    display: grid;
    justify-items: center;
    gap: var(--space-4);
    padding: 40px var(--space-16);
    text-align: center;
    color: var(--text-muted);
  }

  .empty-title {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
    color: var(--text-primary);
  }

  .empty-copy {
    font-size: var(--font-size-sm);
  }

  .download-group {
    display: grid;
    /* minmax(0, ...) so the auto track can't grow to the nowrap filename's min-content */
    grid-template-columns: minmax(0, 1fr);
  }

  .download-group + .download-group {
    margin-top: 22px;
  }

  .download-group-title {
    margin-bottom: var(--space-8);
    padding-inline: 4px;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }
</style>
