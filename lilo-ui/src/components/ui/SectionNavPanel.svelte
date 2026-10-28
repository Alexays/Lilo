<script lang="ts" generics="Id extends string">
  import type { ComponentProps, Snippet } from "svelte";
  import PanelHeader from "./PanelHeader.svelte";
  import SettingsIcon from "../settings/SettingsIcon.svelte";
  import { tooltip } from "../../lib/tooltip";

  interface SectionNavSection {
    id: Id;
    label: string;
    icon?: ComponentProps<typeof SettingsIcon>["name"];
    /** Search hits in this section; shown at the row's end. */
    count?: number;
    dimmed?: boolean;
    /** Something in the section waits on the user: a dot at the row's end. */
    attention?: boolean;
  }

  interface SectionNavGroup {
    id: string;
    /** Unlabelled groups are set apart by a separator instead. */
    label?: string;
    sections: SectionNavSection[];
  }

  interface Props {
    title: string;
    ariaLabel: string;
    groups: SectionNavGroup[];
    /** null while no row is current (search results). */
    activeId: Id | null;
    onSelect: (id: Id) => void;
    onclose: () => void;
    /** Rendered under the header, above the rows (the settings search). */
    toolbar?: Snippet;
    /** Icons only, each named by a tooltip: the toolbar and group labels step aside. */
    compact?: boolean;
  }

  let { title, ariaLabel, groups, activeId, onSelect, onclose, toolbar, compact = false }: Props = $props();
</script>

<div class="panel-shell section-nav-panel" class:compact>
  <PanelHeader {title} {onclose} />

  {#if toolbar && !compact}
    <div class="section-nav-toolbar">{@render toolbar()}</div>
  {/if}

  <nav class="section-nav" aria-label={ariaLabel}>
    {#each groups as group, index (group.id)}
      {#if group.label && !compact}
        <div class="section-nav-group-label">{group.label}</div>
      {:else if index > 0}
        <div class="section-nav-separator" role="separator"></div>
      {/if}
      <section class="section-nav-group" aria-label={group.label}>
        {#each group.sections as section (section.id)}
          <button
            class:active={section.id === activeId}
            class:dimmed={section.dimmed}
            class="section-nav-button"
            type="button"
            aria-current={section.id === activeId ? "page" : undefined}
            onclick={() => onSelect(section.id)}
            use:tooltip={{ text: section.label, placement: "right", disabled: !compact }}
          >
            {#if section.icon != null}
              <span class="section-nav-icon" aria-hidden="true">
                <SettingsIcon name={section.icon} />
              </span>
            {/if}
            <span class="section-nav-label">{section.label}</span>
            {#if section.count}
              <span class="section-nav-count">{section.count}</span>
            {:else if section.attention}
              <span class="section-nav-attention" aria-hidden="true"></span>
            {/if}
          </button>
        {/each}
      </section>
    {/each}
  </nav>
</div>

<style>
  .section-nav-panel {
    min-height: 0;
  }

  .section-nav-toolbar {
    padding: 0 var(--sidebar-right-pad, 10px) 8px 10px;
  }

  .section-nav {
    display: grid;
    align-content: start;
    min-height: 0;
    overflow-y: auto;
    padding: 4px var(--sidebar-right-pad, 10px) 14px 10px;
  }

  .section-nav-group {
    display: grid;
    gap: 2px;
  }

  /* The sidebar's space label. */
  .section-nav-group-label {
    padding: 12px 6px 6px;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.5px;
    text-transform: uppercase;
  }

  .section-nav-group-label:first-child {
    padding-top: 4px;
  }

  .section-nav-separator {
    height: 1px;
    margin: 8px 10px;
    background: var(--separator);
  }

  /* Rows are sidebar tab rows: same height, radius, hover, and active pill. */
  .section-nav-button {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    height: 28px;
    padding: 0 8px;
    border: 0;
    border-radius: var(--radius-md);
    background: transparent;
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-md);
    text-align: left;
    cursor: pointer;
    transition:
      background var(--transition-fast),
      box-shadow var(--transition-fast),
      color var(--transition-fast);
  }

  .section-nav-button:hover {
    background: var(--bg-hover);
  }

  .section-nav-button.active {
    background: var(--bg-active);
    box-shadow:
      0 0 0 1px color-mix(in srgb, var(--bg-active) 54%, transparent),
      0 0 12px 0 color-mix(in srgb, var(--bg-active) 72%, transparent);
  }

  .section-nav-button.dimmed {
    color: var(--text-muted);
  }

  .section-nav-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .section-nav-icon {
    flex: none;
    display: grid;
    place-items: center;
    width: 16px;
    height: 16px;
    color: var(--text-secondary);
  }

  .section-nav-button.dimmed .section-nav-icon {
    color: var(--text-muted);
  }

  .section-nav-label {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .section-nav-count {
    flex: none;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
  }

  .compact .section-nav {
    padding-inline: var(--space-8);
  }

  .compact .section-nav-button {
    justify-content: center;
    padding: 0;
  }

  .compact :is(.section-nav-count, .section-nav-attention) {
    display: none;
  }

  /* Out of sight, still the button's name. */
  .compact .section-nav-label {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
  }

  .section-nav-attention {
    flex: none;
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--accent);
  }
</style>
