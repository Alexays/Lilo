<script lang="ts">
  import { ICONS, type IconName } from "./icons";

  let { name, size = 14 }: { name: IconName; size?: number } = $props();
</script>

<svg
  class="icon"
  width={size}
  height={size}
  viewBox="0 0 16 16"
  fill="none"
  stroke="currentColor"
  stroke-width="1.5"
  stroke-linecap="round"
  stroke-linejoin="round"
  aria-hidden="true"
>
  <!-- Non-scaling, so every size draws the same 1.5px line. -->
  <path d={ICONS[name]} vector-effect="non-scaling-stroke" />
</svg>

<style>
  .icon {
    flex: none;
  }
</style>
