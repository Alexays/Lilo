<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getOnboarding, goBack, goNext } from "../../stores/onboarding.svelte";

  const onboarding = getOnboarding();
  const develop = $derived(onboarding.usage === "develop");
  const tips = $derived(develop ? ["inspector", "localhost", "agents"] : ["search", "tabs", "split"]);
  const keys = $derived(develop ? "onboarding.devTips" : "onboarding.tips");
</script>

<h3>{t(`${keys}.title`)}</h3>
<p class="ob-sub">{t(`${keys}.subtitle`)}</p>

<ul class="tips">
  {#each tips as tip (tip)}
    <li>
      <div class="anim a-{tip}" aria-hidden="true">
        {#if tip === "search"}<span class="bar2"></span>
        {:else if tip === "tabs"}<span class="col"><i></i><i></i><i></i></span>
        {:else if tip === "inspector"}<span class="insp"></span>
        {:else if tip === "agents"}<span class="term"></span>
        {:else}<span class="l"></span><span class="r"></span>{/if}
      </div>
      <span>{t(`${keys}.${tip}`)}</span>
    </li>
  {/each}
</ul>

<div class="ob-foot">
  <button class="ob-btn ghost" onclick={goBack}>{t("onboarding.back")}</button>
  <button class="ob-btn primary" onclick={goNext}>{t("onboarding.tips.go")}</button>
</div>

<style>
  .tips { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
  .tips li { display: flex; align-items: center; gap: 14px; padding: 8px; border-radius: var(--radius-lg); background: var(--bg-hover); font-size: var(--font-size-lg); color: var(--text-primary); }
  .anim { position: relative; width: 96px; height: 60px; flex: none; border-radius: var(--radius-md); background: var(--bg-primary); overflow: hidden; }
  .col { position: absolute; left: 8px; top: 8px; bottom: 8px; width: 30px; display: flex; flex-direction: column; gap: 4px; }
  .col i { height: 9px; border-radius: var(--radius-xs); background: var(--accent); opacity: 0; animation: row 3s infinite var(--motion-ease-spring); }
  .col i:nth-child(2) { animation-delay: .15s; } .col i:nth-child(3) { animation-delay: .3s; }
  @keyframes row { 0%, 10% { opacity: 0; transform: translateX(-12px); } 25%, 85% { opacity: .7; transform: none; } 100% { opacity: 0; } }
  .bar2 { position: absolute; left: 14%; right: 14%; top: 18px; height: 22px; border-radius: var(--radius-md); background: var(--bg-hover); box-shadow: var(--shadow-sm); animation: cmd 3s infinite var(--motion-ease-spring); }
  .bar2::after { content: ""; position: absolute; left: 10px; top: 9px; height: 8px; border-radius: var(--radius-xs); background: var(--accent); opacity: .5; animation: type 3s infinite steps(8); }
  @keyframes cmd { 0%, 10% { opacity: 0; transform: scale(.9) translateY(-6px); } 20%, 80% { opacity: 1; transform: none; } 90%, 100% { opacity: 0; } }
  @keyframes type { 0%, 20% { width: 0; } 60%, 100% { width: 60%; } }
  .l, .r { position: absolute; top: 8px; bottom: 8px; border-radius: var(--radius-sm); }
  .l { left: 8px; background: #e9defe; animation: spl 3s infinite var(--motion-ease-spring); }
  .r { right: 8px; background: #ffe3d1; animation: spr 3s infinite var(--motion-ease-spring); }
  @keyframes spl { 0%, 20% { right: 8px; } 40%, 85% { right: calc(50% + 3px); } 100% { right: 8px; } }
  @keyframes spr { 0%, 20% { left: 100%; opacity: 0; } 40%, 85% { left: calc(50% + 3px); opacity: 1; } 100% { left: 100%; opacity: 0; } }
  .insp { position: absolute; left: 8px; right: 8px; bottom: 8px; height: 20px; border-radius: var(--radius-sm); background: #1a1a2e; animation: insp 3s infinite var(--motion-ease-spring); }
  .insp::after { content: ""; position: absolute; left: 7px; top: 7px; width: 45%; height: 5px; border-radius: var(--radius-xs); background: #9b80f6; }
  @keyframes insp { 0%, 15% { transform: translateY(130%); } 35%, 85% { transform: none; } 100% { transform: translateY(130%); } }
  /* A local server's port: "localhost" would not fit the half pane, at WebKit's minimum font size either. */
  .a-localhost .r { overflow: hidden; }
  .a-localhost .r::after { content: ":3000"; position: absolute; inset: 0; display: grid; place-items: center; font: var(--font-weight-semibold) 7px/1 ui-monospace, monospace; color: #993c1d; }
  .term { position: absolute; inset: 8px; border-radius: var(--radius-sm); background: #1a1a2e; }
  .term::before { content: "$"; position: absolute; left: 7px; top: 6px; font: var(--font-weight-semibold) var(--font-size-3xs)/1 ui-monospace, monospace; color: #5dcaa5; }
  .term::after { content: ""; position: absolute; left: 17px; top: 7px; height: 7px; border-radius: var(--radius-2xs); background: #9fe1cb; animation: type 3s infinite steps(8); }
  @media (prefers-reduced-motion: reduce) { .anim :global(*) { animation: none !important; } }
</style>