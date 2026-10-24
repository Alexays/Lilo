<script lang="ts" module>
  export type UrlDrawerIconName =
    | "camera"
    | "microphone"
    | "location"
    | "notifications"
    | "extension"
    | "agent"
    | "zoom"
    | "browser";
</script>

<script lang="ts">
  let { name }: { name: UrlDrawerIconName } = $props();
</script>

<svg class="url-drawer-icon" viewBox="0 0 20 20" aria-hidden="true">
  {#if name === "camera"}
    <rect x="2.8" y="5.6" width="10.4" height="8.8" rx="2" />
    <path d="m13.2 8.8 4-2.2v6.8l-4-2.2" />
  {:else if name === "microphone"}
    <rect x="7.4" y="2.8" width="5.2" height="9" rx="2.6" />
    <path d="M4.8 9.6a5.2 5.2 0 0 0 10.4 0M10 14.8v2.4" />
  {:else if name === "location"}
    <path d="M10 17.2s5.2-4.6 5.2-8.8a5.2 5.2 0 0 0-10.4 0c0 4.2 5.2 8.8 5.2 8.8Z" />
    <circle cx="10" cy="8.4" r="1.9" />
  {:else if name === "notifications"}
    <path d="M5.4 13.6V9a4.6 4.6 0 0 1 9.2 0v4.6l1.2 1.6H4.2l1.2-1.6Z" />
    <path d="M8.4 17.2a1.8 1.8 0 0 0 3.2 0" />
  {:else if name === "extension"}
    <path d="M4.4 7.4h2.8a1.9 1.9 0 1 1 3.8 0h2.8v2.8a1.9 1.9 0 1 1 0 3.8v2.6H4.4V7.4Z" />
  {:else if name === "agent"}
    <path d="m5 3.6 9.4 5.2-4 1.2 2.6 4.6-1.8 1-2.6-4.6-3 2.8Z" />
  {:else if name === "zoom"}
    <circle cx="8.8" cy="8.8" r="5" />
    <path d="m12.6 12.6 4 4M8.8 6.6v4.4M6.6 8.8h4.4" />
  {:else if name === "browser"}
    <circle cx="10" cy="10" r="6.6" />
    <path d="m12.8 7.2-1.6 4-4 1.6 1.6-4 4-1.6Z" />
  {/if}
</svg>

<style>
  .url-drawer-icon {
    width: 16px;
    height: 16px;
    flex: none;
    display: block;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.5;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
</style>
