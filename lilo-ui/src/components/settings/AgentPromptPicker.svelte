<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";

  // What each prompt changes in how the agent behaves, one glyph per point.
  const CHOICES = [
    { id: "lilo", points: [["browse", "globe"], ["act", "bolt"], ["design", "brush"]] },
    { id: "agent", points: [["same", "window"], ["asks", "hand"], ["updates", "refresh"]] },
  ] as const;

  const GLYPHS: Record<string, string> = {
    globe: "M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2ZM2 8h12M8 2c1.8 1.7 2.7 3.7 2.7 6s-.9 4.3-2.7 6c-1.8-1.7-2.7-3.7-2.7-6S6.2 3.7 8 2Z",
    bolt: "M9 1.8 3.8 9h4l-1 5.2L12.2 7h-4Z",
    brush: "M13.6 2.4 7.2 8.8M7.2 8.8l-1.4-.4a2.2 2.2 0 0 0-2.7 1.6L2.4 13.6l3.6-.7a2.2 2.2 0 0 0 1.6-2.7Z",
    window: "M2.5 3.5h11v9h-11ZM2.5 6h11M4.5 4.8h.1M6.3 4.8h.1",
    hand: "M5.5 8V3.6a1 1 0 0 1 2 0V7.5M7.5 7V2.8a1 1 0 0 1 2 0V7.5M9.5 7.2V4a1 1 0 0 1 2 0v5.2c0 2.6-1.8 4.6-4.2 4.6-1.6 0-2.6-.7-3.5-2.1L2.5 9.2a1 1 0 0 1 1.6-1.1L5.5 9.6",
    refresh: "M13 4.5V2.2M13 4.5h-2.3M12.6 4.4A5.2 5.2 0 1 0 13.2 9",
  };

  const selected = $derived(getSetting("agentSystemPrompt", "lilo"));
</script>

<div class="choices" role="radiogroup" aria-label={t("settings.items.agentSystemPrompt.title")}>
  {#each CHOICES as choice (choice.id)}
    <button
      class="choice"
      class:on={selected === choice.id}
      type="button"
      role="radio"
      aria-checked={selected === choice.id}
      onclick={() => setSetting("agentSystemPrompt", choice.id)}
    >
      <span class="head">
        <span class="tile {choice.id}" aria-hidden="true">
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
            <path d={choice.id === "lilo" ? GLYPHS.globe : "m3.5 4.5 3.5 3.5-3.5 3.5M8.5 11.5h4"} />
          </svg>
        </span>
        <span class="label">{t(`settings.items.agentSystemPrompt.${choice.id}`)}</span>
        <span class="radio" aria-hidden="true">
          <svg width="10" height="10" viewBox="0 0 10 10" fill="none"><path d="m2.2 5.2 1.9 1.9 3.8-4" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" /></svg>
        </span>
      </span>
      <span class="points">
        {#each choice.points as [key, glyph] (key)}
          <span class="point">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <path d={GLYPHS[glyph]} />
            </svg>
            {t(`settings.items.agentSystemPrompt.${choice.id}Points.${key}`)}
          </span>
        {/each}
      </span>
    </button>
  {/each}
</div>

<style>
  .choices {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 260px));
    gap: 12px;
    margin-top: 12px;
  }

  .choice {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    align-content: start;
    gap: 12px;
    padding: 12px 14px 14px;
    border: 0;
    border-radius: var(--radius-lg);
    background: var(--bg-primary);
    box-shadow: 0 0 0 1px var(--separator);
    color: var(--text-secondary);
    font: inherit;
    text-align: left;
    cursor: pointer;
    transition: box-shadow var(--motion-duration-fast) var(--motion-ease-organic), background-color var(--motion-duration-fast) var(--motion-ease-organic);
  }

  .choice:hover:not(.on) {
    box-shadow: 0 0 0 1px var(--text-primary-tint-12);
  }

  .choice.on {
    background: color-mix(in srgb, var(--accent) 6%, var(--bg-primary));
    box-shadow: 0 0 0 2px var(--accent);
  }

  .choice:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 3px;
  }

  .head {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .tile {
    display: grid;
    flex: none;
    place-items: center;
    width: 28px;
    height: 28px;
    border-radius: var(--radius-md);
  }

  .tile.lilo {
    background: var(--accent);
    color: var(--bg-primary);
  }

  .tile.agent {
    background: color-mix(in srgb, var(--text-primary) 8%, var(--bg-primary));
    color: var(--text-secondary);
  }

  .label {
    flex: 1;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  /* An empty ring, filled with a check once chosen. */
  .radio {
    display: grid;
    flex: none;
    place-items: center;
    width: 18px;
    height: 18px;
    border-radius: 50%;
    box-shadow: inset 0 0 0 1.5px var(--text-primary-tint-12);
    color: transparent;
  }

  .choice.on .radio {
    background: var(--accent);
    box-shadow: none;
    color: var(--bg-primary);
  }

  .points {
    display: grid;
    gap: 7px;
  }

  .point {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    font-size: var(--font-size-sm);
    line-height: 1.35;
  }

  .point svg {
    flex: none;
    margin-top: 1px;
    color: var(--text-muted);
  }

  .choice.on .point svg {
    color: var(--accent);
  }

  @media (prefers-reduced-motion: reduce) {
    .choice {
      transition: none;
    }
  }
</style>
