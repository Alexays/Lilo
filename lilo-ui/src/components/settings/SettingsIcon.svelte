<script lang="ts">
  import type { SettingsSectionId } from "../../stores/panels.svelte";

  interface Props {
    name: SettingsSectionId;
  }

  let { name }: Props = $props();
</script>

<svg class="settings-icon-svg" viewBox="0 0 20 20" aria-hidden="true">
  {#if name === "general"}
    <path d="M4 6.5h7.2" />
    <path d="M14.6 6.5H16" />
    <path d="M4 13.5h1.4" />
    <path d="M8.8 13.5H16" />
    <circle cx="12.8" cy="6.5" r="1.6" />
    <circle cx="7.2" cy="13.5" r="1.6" />
  {:else if name === "appearance"}
    <circle cx="10" cy="10" r="3.1" />
    <path d="M10 2.9v1.4" />
    <path d="M10 15.7v1.4" />
    <path d="M2.9 10h1.4" />
    <path d="M15.7 10h1.4" />
    <path d="m5 5 1 1" />
    <path d="m14 14 1 1" />
    <path d="m15 5-1 1" />
    <path d="m6 14-1 1" />
  {:else if name === "terminal"}
    <rect x="2.8" y="3.8" width="14.4" height="12.4" rx="2.6" />
    <path d="m6.2 8 2.4 2-2.4 2" />
    <path d="M10.4 12.4h3.4" />
  {:else if name === "tabs"}
    <rect x="3.4" y="6.2" width="10.4" height="10.4" rx="2.6" />
    <path d="M6.4 3.4h7.6a2.6 2.6 0 0 1 2.6 2.6v7.6" />
  {:else if name === "privacy"}
    <path d="M10 2.8 4.8 5v4.4c0 3.2 2 5.8 5.2 7.8 3.2-2 5.2-4.6 5.2-7.8V5L10 2.8Z" />
    <path d="m7.8 10 1.5 1.5 3-3.2" />
  {:else if name === "extensions"}
    <path d="M4.4 7.4h2.8a1.9 1.9 0 1 1 3.8 0h2.8v2.8a1.9 1.9 0 1 1 0 3.8v2.6H4.4V7.4Z" />
  {:else if name === "agents"}
    <path d="m5 3.6 9.4 5.2-4 1.2 2.6 4.6-1.8 1-2.6-4.6-3 2.8Z" />
  {:else if name === "advanced"}
    <path d="M8 3.4h4" />
    <path d="M8.8 3.4v4.4l-4.1 6.8c-.6 1 .1 2.1 1.2 2.1h8.2c1.1 0 1.8-1.1 1.2-2.1l-4.1-6.8V3.4" />
    <path d="M6.6 12.4h6.8" />
  {/if}
</svg>

<style>
  .settings-icon-svg {
    width: 16px;
    height: 16px;
    display: block;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.6;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
</style>
