<script lang="ts">
  import { untrack } from "svelte";
  import { demoCopy, pageProjects } from "./world.ts";
  import type { DemoLocale } from "./world.ts";

  interface Props {
    tabId: string;
    locale: DemoLocale;
  }

  let { tabId, locale }: Props = $props();
  const text = $derived(demoCopy(locale));
  let project = $state(untrack(() => pageProjects.get(tabId) ?? { completed: [false, false, true], published: false, update: "" }));
  const complete = $derived(project.completed.every(Boolean));

  $effect(() => {
    pageProjects.set(tabId, { completed: [...project.completed], published: project.published, update: project.update });
  });
</script>

<article class="launch-page">
  <header><span>Studio</span><span class="crumb" aria-hidden="true">/</span><span>{text.agentProject}</span></header>
  <div class="project-cover" aria-hidden="true"></div>
  <div class="project-body">
    <span class="eyebrow">Studio / 01</span>
    <h1>{text.agentProject}</h1>
    <section aria-label={text.agentChecklist}>
      <div class="section-heading"><h2>{text.agentChecklist}</h2><span>{project.completed.filter(Boolean).length} / 3</span></div>
      <div class="checklist">{#each [text.agentCheckOne, text.agentCheckTwo, text.agentCheckThree] as label, index (index)}
        <label class:complete={project.completed[index]}><input type="checkbox" aria-label={label} bind:checked={project.completed[index]} onchange={() => { project.published = false; }} /><span>{label}</span></label>
      {/each}</div>
    </section>
    <section class="project-update">
      <label for={`update-${tabId}`}>{text.agentUpdate}</label>
      <textarea id={`update-${tabId}`} aria-label={text.agentUpdate} bind:value={project.update} oninput={() => { project.published = false; }} rows="4" spellcheck="false"></textarea>
      <div class="publish-row"><span class="published" role="status">{#if project.published}<span aria-hidden="true">✓</span> {text.agentPublished}{/if}</span><button type="button" data-agent-approval disabled={!complete || !project.update.trim() || project.published} onclick={() => { project.published = true; }}>{text.agentPublish}</button></div>
    </section>
  </div>
</article>

<style>
  .launch-page { min-height: 100%; font: 12px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  header { display: flex; gap: 9px; align-items: center; padding: 14px 20px; border-bottom: 1px solid var(--border); color: var(--text-secondary); font-size: 11px; }
  .crumb { color: var(--text-muted); }
  .project-cover { position: relative; height: 95px; overflow: hidden; background: color-mix(in srgb, #b7c3ad 24%, var(--bg-primary)); }
  .project-body { max-width: 620px; margin: 0 auto; padding: 24px; }
  .eyebrow { color: var(--text-muted); font-size: 10px; text-transform: uppercase; letter-spacing: 1px; }
  h1 { margin: 6px 0 24px; font-size: 26px; font-weight: 650; line-height: 1.2; letter-spacing: -.7px; }
  .section-heading { display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px; }
  h2 { margin: 0; font-size: 12px; font-weight: 600; }
  .section-heading > span { color: var(--text-muted); font-size: 10px; font-variant-numeric: tabular-nums; }
  .checklist { border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
  .checklist label { display: flex; gap: 10px; align-items: center; padding: 10px 12px; border-bottom: 1px solid var(--border); cursor: pointer; }
  .checklist label:last-child { border-bottom: 0; }
  input { margin: 0; accent-color: #73916e; }
  .complete span { color: var(--text-muted); text-decoration: line-through; }
  .project-update { margin-top: 24px; }
  .project-update > label { display: block; margin-bottom: 8px; font-weight: 600; }
  textarea { display: block; width: 100%; min-height: 105px; resize: vertical; box-sizing: border-box; padding: 10px 12px; border: 1px solid var(--border); border-radius: 8px; background: var(--bg-hover); color: var(--text-primary); font: inherit; line-height: 1.6; }
  .publish-row { display: flex; gap: 10px; align-items: center; justify-content: space-between; margin-top: 10px; }
  .published { color: #73916e; font-size: 10px; }
  button { display: flex; align-items: center; gap: 12px; border: 0; border-radius: 7px; padding: 8px 11px; background: var(--text-primary); color: var(--bg-primary); font: inherit; font-size: 11px; font-weight: 600; cursor: pointer; }
  button:disabled { opacity: .4; cursor: default; }
  button:focus-visible, input:focus-visible, textarea:focus-visible { outline: var(--focus-outline); outline-offset: 3px; }
</style>
