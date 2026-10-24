<script lang="ts" module>
  export interface DetailRow {
    label: string;
    value: string;
    tone?: "success" | "danger" | "muted";
    /** "tag" for a name like a branch, "code" for a command line. */
    look?: "tag" | "code";
    lock?: boolean;
    /** Muted text after the value, on the same line. */
    extra?: string;
    /** A muted line under the value, led by the terminal tab's dot when `state` is set. */
    note?: string;
    state?: "busy" | "waiting" | "failed";
    /** Named on the right of the value, as a link. */
    action?: { label: string; run: (e: MouseEvent) => void };
  }

  export interface DetailAction {
    label: string;
    run: (e: MouseEvent) => void;
    added?: number;
    removed?: number;
  }

  /** The full address or path, `strong` set in bold like the bar shows it. */
  export interface DetailLocation {
    before: string;
    strong: string;
    after: string;
    code: boolean;
  }
</script>

<script lang="ts">
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { fly } from "svelte/transition";
  import { cubicOut } from "svelte/easing";

  interface Props {
    /** Empty when the bar already shows it. */
    title: string;
    location: DetailLocation;
    rows: DetailRow[];
    actions: DetailAction[];
  }

  let { title, location, rows, actions }: Props = $props();

  const compactCount = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
</script>

<div
  class="url-details float-surface"
  role="group"
  aria-label={title || location.before + location.strong + location.after}
  transition:fly={{ y: -4, duration: prefersReducedMotion() ? 0 : 160, easing: cubicOut }}
>
  <div class="heading">
    {#if title}<div class="title">{title}</div>{/if}
    <div class="location" class:code={location.code}>{location.before}<b>{location.strong}</b>{location.after}</div>
  </div>
  {#if rows.length > 0}
    <dl class="rows">
      {#each rows as row (row.label)}
        <div class="row" class:code={row.look === "code"}>
          <dt>{row.label}</dt>
          <dd class="value look-{row.look ?? 'text'} tone-{row.tone ?? 'plain'}">
            {#if row.lock}
              <svg class="lock" width="10" height="11" viewBox="0 0 10 11" fill="none" aria-hidden="true">
                <rect x="1" y="4.5" width="8" height="6" rx="1.6" fill="currentColor"/>
                <path d="M3 4.5V3.2a2 2 0 0 1 4 0v1.3" stroke="currentColor" stroke-width="1.2"/>
              </svg>
            {/if}
            <span class="text">{#if row.look === "tag"}<span class="tag">{row.value}</span>{:else}{row.value}{/if}{#if row.extra}<span class="extra"> · {row.extra}</span>{/if}</span>
            {#if row.action}
              <button type="button" class="row-action" onclick={row.action.run}>
                {row.action.label}
                <svg width="6" height="9" viewBox="0 0 6 9" fill="none" aria-hidden="true">
                  <path d="M1.5 1.5L4.5 4.5L1.5 7.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>
                </svg>
              </button>
            {/if}
          </dd>
          {#if row.note}
            <dd class="note">
              {#if row.state}<span class="dot" data-state={row.state}></span>{/if}
              <span class="note-text">{row.note}</span>
            </dd>
          {/if}
        </div>
      {/each}
    </dl>
  {/if}
  {#if actions.length > 0}
    <div class="actions">
      {#each actions as action (action.label)}
        <button type="button" class="action" onclick={action.run}>
          {#if action.added || action.removed}
            <span class="counts">
              {#if action.added}<span class="added">+{compactCount.format(action.added)}</span>{/if}
              {#if action.removed}<span class="removed">-{compactCount.format(action.removed)}</span>{/if}
            </span>
          {/if}
          {action.label}
        </button>
      {/each}
    </div>
  {/if}
</div>

<style>
  /* Under the bar and as wide as it; a child of the bar's container, so tabbing reaches it. */
  .url-details {
    position: absolute;
    top: calc(100% + 2px);
    left: 10px;
    right: var(--sidebar-right-pad, 10px);
    z-index: 30;
    box-sizing: border-box;
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 10px;
    border-radius: var(--float-radius-card);
    font-size: var(--font-size-sm);
  }

  .heading {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .title {
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
    line-height: 1.35;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
    overflow-wrap: anywhere;
  }

  /* The full address or path, wrapped, since the bar only shows its ends. */
  .location {
    font-size: var(--font-size-xs);
    line-height: 1.4;
    color: var(--text-muted);
    overflow-wrap: anywhere;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .location b {
    color: var(--text-secondary);
    font-weight: var(--font-weight-semibold);
  }

  .location.code {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    -webkit-line-clamp: 3;
    line-clamp: 3;
  }

  /* A terminal's folder is the card's title: it reads like one. */
  .heading:not(:has(.title)) .location.code {
    font-size: var(--font-size-sm);
    color: var(--text-secondary);
  }

  .location.code b {
    color: var(--text-primary);
  }

  /* Label and value side by side; each row's cells join the grid's columns. */
  .rows {
    display: grid;
    grid-template-columns: max-content minmax(0, 1fr);
    column-gap: 12px;
    row-gap: 6px;
    margin: 0;
  }

  .row {
    display: contents;
  }

  dt {
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    line-height: 1.6;
  }

  dd {
    grid-column: 2;
    margin: 0;
  }

  /* A command gets a block of its own, its state underneath; the label stays for screen readers. */
  .row.code {
    display: flex;
    flex-direction: column;
    gap: 4px;
    grid-column: 1 / -1;
    padding: 8px;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
  }

  .row.code dt {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }

  .value {
    display: flex;
    align-items: center;
    gap: 4px;
    min-width: 0;
    font-size: var(--font-size-sm);
    line-height: 1.45;
  }

  .text {
    min-width: 0;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
    overflow-wrap: anywhere;
  }

  .extra {
    color: var(--text-muted);
  }

  .look-code .text {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: var(--font-size-xs);
    -webkit-line-clamp: 3;
    line-clamp: 3;
  }

  /* Not clamped: the clipping would cut the tag's padding. A long name wraps into stacked tags. */
  .look-tag .text {
    display: block;
    overflow: visible;
  }

  .tag {
    font: var(--font-weight-medium) var(--font-size-xs)/1.6 ui-monospace, "SF Mono", Menlo, monospace;
  }

  .lock {
    flex: none;
  }

  .row-action {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    flex: none;
    margin: -2px -4px -2px auto;
    padding: 2px 4px;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-muted);
    font: inherit;
    font-size: var(--font-size-xs);
    cursor: pointer;
    transition:
      background var(--transition-fast),
      color var(--transition-fast);
  }

  .row-action:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .row-action:focus-visible,
  .action:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  /* No clipping here: the dot must stay whole, only the text gives way. */
  .note {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  .note-text {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* The same colors as the tab's pip. */
  .dot {
    flex: none;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: color-mix(in srgb, var(--accent) 55%, white);
  }

  .dot[data-state="failed"] {
    background: var(--danger);
  }

  .tone-success .text,
  .tone-success .lock {
    color: var(--success);
  }

  .tone-danger .text {
    color: var(--danger-text);
  }

  .tone-muted .text {
    color: var(--text-muted);
  }

  .actions {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    padding-top: 8px;
    border-top: 1px solid var(--separator);
  }

  .action {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    height: 24px;
    padding: 0 10px;
    border: 0;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .action:hover {
    background: var(--bg-active);
  }

  .counts {
    display: inline-flex;
    gap: 4px;
    font: var(--font-weight-semibold) var(--font-size-xs)/1 ui-monospace, "SF Mono", Menlo, monospace;
    font-variant-numeric: tabular-nums;
  }

  .counts .added {
    color: var(--success);
  }

  .counts .removed {
    color: var(--danger);
  }
</style>
