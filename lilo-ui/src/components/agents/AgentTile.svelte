<script lang="ts" module>
  let catalogRequested = false;
</script>

<script lang="ts">
  import { conversationActions } from "./conversationActions";
  import { modelLogo } from "./modelLogos";
  import { getAgent, getAgents } from "../../stores/conversations.svelte";

  let { agentId }: { agentId: string } = $props();

  const agent = $derived(getAgent(agentId));
  // The registry names and draws the agents: asked once, by the first tile with nothing to show.
  $effect(() => {
    if (catalogRequested || getAgents().length > 0) return;
    catalogRequested = true;
    conversationActions.loadCatalog(false);
  });
  // A known provider shows its own logo in its colour; otherwise the registry's monochrome icon, drawn as
  // a mask so it takes the tile's ink in both themes.
  const logo = $derived(modelLogo(`${agentId} ${agent?.name ?? ""}`));
  const icon = $derived(agent?.icon ? `url("${agent.icon.replaceAll('"', "%22")}")` : undefined);
</script>

{#if logo}
  <svg class="agent-logo" width="16" height="16" viewBox="0 0 24 24" aria-hidden="true" style:color={logo.color}>
    <path d={logo.path} />
  </svg>
{:else}
  <span class="agent-tile" class:glyph={!!icon} style:--agent-icon={icon} aria-hidden="true">
    {#if !icon}{(agent?.name || agentId || "?").charAt(0).toUpperCase()}{/if}
  </span>
{/if}

<style>
  .agent-logo {
    flex: none;
    fill: currentColor;
  }

  /* A 16px favicon's box, like the terminal tile beside it. */
  .agent-tile {
    flex: none;
    width: 16px;
    height: 16px;
    box-sizing: border-box;
    border-radius: var(--radius-xs);
    display: grid;
    place-items: center;
    background: var(--agents);
    color: var(--on-color);
    font-size: var(--font-size-3xs);
    font-weight: var(--font-weight-bold);
    line-height: 1;
  }

  .agent-tile.glyph {
    background: var(--terminal-tile-bg);
    box-shadow: inset 0 0 0 1px var(--terminal-tile-border);
  }

  .agent-tile.glyph::before {
    content: "";
    width: 11px;
    height: 11px;
    background: var(--terminal-tile-text);
    mask: var(--agent-icon) center / contain no-repeat;
  }
</style>
