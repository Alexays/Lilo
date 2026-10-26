<script lang="ts">
  import { onMount, untrack } from "svelte";
  import type { DemoHost } from "./host.ts";
  import { getPlayground } from "./playground.ts";
  import { demoCopy } from "./world.ts";
  import type { DemoLocale } from "./world.ts";

  let { host, locale }: { host: DemoHost; locale: DemoLocale } = $props();
  const text = $derived(demoCopy(locale));
  const playground = untrack(() => getPlayground(host));
  const workspace = "/Users/you/Projects/lilo";
  let directory = $state(workspace);
  let files = $state<{ name: string; directory: boolean }[]>([]);
  let selected = $state("README.md");
  let content = $state("");
  let error = $state("");
  let loading = $state(true);
  let refreshing = $state(true);
  let generation = 0;

  const refresh = async () => {
    generation += 1;
    refreshing = true;
    const current = generation;

    try {
      const names = await playground.shell.fs.readdir(directory);

      const entries = await Promise.all(names.map(async (name) => {
        const path = `${directory}/${name}`;
        const stat = await playground.shell.fs.stat(path).catch(() => playground.shell.fs.lstat(path));

        return { directory: stat.isDirectory, name };
      }));

      const file = entries.some((entry) => entry.name === selected && !entry.directory) ? selected : entries.find((entry) => !entry.directory)?.name ?? "";
      let fileError = "";

      const source = file ? await playground.shell.fs.readFile(`${directory}/${file}`).catch((error_) => {
        fileError = error_ instanceof Error ? error_.message : String(error_);

        return "";
      }) : "";

      if (current !== generation) {return;}

      files = entries.toSorted((first, second) => Number(second.directory) - Number(first.directory) || first.name.localeCompare(second.name));
      selected = file;
      content = source.slice(0, 64_000);
      error = fileError;
    } catch (error_) {
      if (current === generation) {error = error_ instanceof Error ? error_.message : String(error_);}
    } finally { if (current === generation) { loading = false; refreshing = false; } }
  };

  const open = (entry: { name: string; directory: boolean }) => {
    if (entry.directory) {directory = `${directory}/${entry.name}`;}
    else {selected = entry.name;}

    void refresh();
  };

  const up = () => { directory = directory.slice(0, directory.lastIndexOf("/")) || workspace; void refresh(); };

  onMount(() => {
    void refresh();
    const unsubscribe = playground.subscribe(() => { void refresh(); });

    return () => { generation += 1; unsubscribe(); };
  });
</script>

<section class="project-view" data-page-loading={refreshing ? "true" : undefined} aria-label={text.project}>
  <header><span aria-hidden="true">⌘</span><h1>{text.project}</h1></header>
  <nav class="path" aria-label={text.project}><button type="button" onclick={up} disabled={directory === workspace} aria-label="..">↑</button><span>{directory.replace(workspace, "~/Projects/lilo")}</span></nav>
  {#if loading}<p role="status">{text.projectLoading}</p>{/if}
  {#if error}<p class="error" role="alert">{error}</p>{/if}
  <div class="files">{#each files as entry (entry.name)}<button type="button" class:current={selected === entry.name && !entry.directory} onclick={() => open(entry)}><span aria-hidden="true">{entry.directory ? "▸" : "▤"}</span>{entry.name}</button>{/each}</div>
  {#if !loading && !files.length}<p>{text.projectEmpty}</p>{/if}
  {#if selected}
    <div class="file-heading"><span>{selected}</span><span>{text.projectFile}</span></div>
    <!-- svelte-ignore a11y_no_noninteractive_tabindex (Focus lets keyboard users scroll while reading the file.) -->
    <pre class="workspace-file" aria-label={text.projectFile} role="region" tabindex="0">{content}</pre>
  {/if}
</section>

<style>
  .project-view { padding: 24px; color: var(--text-primary); font: 12px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  header { display: flex; gap: 10px; align-items: center; margin-bottom: 20px; }
  header > span { display: grid; place-items: center; width: 32px; height: 32px; background: var(--bg-hover); border-radius: 8px; font-size: 20px; }
  h1 { margin: 0; font-size: 17px; letter-spacing: -.4px; }
  .path { display: flex; gap: 8px; align-items: center; color: var(--text-secondary); font: 10px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; margin-bottom: 12px; overflow-wrap: anywhere; }
  .path button { width: 26px; height: 26px; flex-shrink: 0; border: 1px solid var(--border); border-radius: 6px; background: var(--bg-hover); color: inherit; cursor: pointer; }
  .path button:disabled { opacity: .3; cursor: default; }
  .files { display: grid; border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
  .files button { display: flex; gap: 9px; align-items: center; padding: 7px 10px; border: 0; border-bottom: 1px solid var(--border); background: none; color: var(--text-secondary); text-align: left; font: 11px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; cursor: pointer; }
  .files button:last-child { border-bottom: 0; }
  .files button.current { color: var(--text-primary); background: var(--bg-hover); }
  .file-heading { display: flex; justify-content: space-between; gap: 8px; margin: 24px 0 9px; color: var(--text-secondary); font-size: 10px; }
  .file-heading span:last-child { color: var(--text-muted); }
  pre { margin: 0; font: 11px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
  button:focus-visible, pre:focus-visible { outline: var(--focus-outline); outline-offset: 2px; }
  .error { color: var(--danger); overflow-wrap: anywhere; }
</style>
