<!-- Lilo's mascot at rest, drawn still: AgentMascot blinks on a timer, which a row at rest must not pay for. -->
<script lang="ts">
  let { outlined = false }: { outlined?: boolean } = $props();
</script>

<svg class="mascot-glyph" class:outlined width="16" height="16" viewBox="0 0 22 22" aria-hidden="true">
  <circle class="body" cx="11" cy="11" r="9.25" />
  <ellipse class="eye" cx="7.5" cy="10" rx="1.8" ry="2.3" />
  <ellipse class="eye" cx="14.5" cy="10" rx="1.8" ry="2.3" />
</svg>

<style>
  .mascot-glyph {
    flex: none;
  }

  .body {
    fill: white;
    stroke: var(--agents);
    stroke-width: 1.5;
  }

  .eye {
    fill: var(--agents);
  }

  /* Drawn in the text color, like the toolbar glyphs beside it. */
  .outlined .body {
    fill: none;
    stroke: currentColor;
  }

  .outlined .eye {
    fill: currentColor;
  }
</style>
