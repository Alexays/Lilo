<script lang="ts">
  interface Props {
    size: number;
  }
  let { size }: Props = $props();

  const PETAL = "M0,-12 C58,-28 114,-108 114,-202 C114,-286 64,-344 0,-344 C-64,-344 -114,-286 -114,-202 C-114,-108 -58,-28 0,-12Z";
  // Light from the top-left: palest petal there, deepest at the bottom-right.
  const PETALS = [
    { angle: -45, from: "#e9dfff", to: "#bea8ff" },
    { angle: 45, from: "#c9b5ff", to: "#9b80f6" },
    { angle: -135, from: "#a98ef8", to: "#7a5deb" },
    { angle: 135, from: "#7d5eee", to: "#4a2fc8" },
  ];
  const uid = Math.random().toString(36).slice(2);
</script>

<svg class="fleuron" width={size} height={size} viewBox="-360 -360 720 720" aria-hidden="true">
  <defs>
    {#each PETALS as petal, i (i)}
      <linearGradient id="fl-{uid}-{i}" x1=".15" y1="0" x2=".85" y2="1">
        <stop offset="0" stop-color={petal.from} />
        <stop offset="1" stop-color={petal.to} />
      </linearGradient>
    {/each}
  </defs>
  {#each PETALS as petal, i (i)}
    <g class="petal" style:--i={i}>
      <path d={PETAL} transform="rotate({petal.angle})" fill="url(#fl-{uid}-{i})" />
    </g>
  {/each}
</svg>

<style>
  .fleuron { overflow: visible; display: block; }
  .petal { transform-box: fill-box; transform-origin: center; }
</style>
