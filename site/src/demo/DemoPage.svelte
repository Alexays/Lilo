<script lang="ts">
import { tick } from "svelte";
import type { BridgeTabSnapshot } from "../../../lilo-ui/src/lib/bridge/protocol";
import type { DemoHost } from "./host";
import { demoCopy, pageNotes } from './world';
import type { DemoLocale } from './world';
import Fleuron from "../../../lilo-ui/src/components/onboarding/Fleuron.svelte";
import SettingsIcon from "../../../lilo-ui/src/components/settings/SettingsIcon.svelte";
import { buildSearchURL } from "../../../lilo-ui/src/lib/inputParser";

let { tab, host, locale, settings, onnavigate, onpreview, onpreviewclose }: {
    tab: BridgeTabSnapshot;
    host: DemoHost;
    locale: DemoLocale;
    settings?: Record<string, string>;
    onnavigate?: (url: string) => void;
    onpreview?: (mode: "peek" | "little", url: string) => void;
    onpreviewclose?: () => void;
} = $props();

const text = $derived(demoCopy(locale));
const preferences = $derived(settings ?? host.snapshot().settings);

type LinkAction = "peek" | "little" | "tab" | "background" | "split" | "copy";

let linkMenu: HTMLDivElement;
let linkTarget: HTMLAnchorElement | undefined;
let linkURL = "";
let menuPosition = $state({ x: 0, y: 0 });

const linkActions = $derived<{ action: LinkAction; label: string }[]>([
    { action: "peek", label: text.linkPeek },
    { action: "tab", label: text.linkTab },
    { action: "background", label: text.linkBackground },
    { action: "split", label: text.linkSplit },
    { action: "little", label: text.linkLittle },
    { action: "copy", label: text.linkCopy },
]);

const zoom = $derived.by(() => { void preferences;

 return tab.kind === "terminal" || new URL(tab.url || "https://example.com").hostname === "mcp.example.com" ? 1 : host.zoomFor(tab.url); });

const minimumFont = $derived(Math.max(0, Math.min(72, Number(preferences.minimumFontSize) || 0)));

const kind = $derived.by(() => {
  if (tab.kind === "terminal") {return "terminal";}

  if (!tab.url) {return "home";}

  const {hostname} = new URL(tab.url);
  const pages = new Map([["mcp.example.com", "mcp"], ["studio.example.com", "launch"], ["project.example.com", "project"], ["github.com", "repo"], ["slowtravel.example.com", "travel"], ["notes.example.com", "notes"], ["radio.example.com", "music"], ["tracker.example.com", "board"]]);

  for (const [domain, page] of pages) {
    if (hostname === domain) { return page; }
  }

  return "sample";
});

const samples = $derived([
    { title: "Lilo", url: "https://github.com/Alexays/Lilo" },
    { title: text.article, url: "https://slowtravel.example.com/lisbon" },
    { title: text.notes, url: "https://notes.example.com" },
    { title: text.playlist, url: "https://radio.example.com/late-night" },
]);

let query = $state("");
let day = $state(0);
let playing = $state(false);
let track = $state(0);
const files = new Set([".changes", ".github", "Lilo", "LiloMCP", "LiloTests", "docs", "lilo-ui", "site", "README.md"]);
const repoBase = "https://github.com/Alexays/Lilo";

const repoSection = $derived.by(() => {
  const address = new URL(tab.url || repoBase);

  if (address.pathname.endsWith("/issues")) { return "issues"; }

  return address.hash === "#readme" ? "readme" : "code";
});

const file = $derived.by(() => {
  const path = new URL(tab.url || repoBase).pathname.split("/").slice(5).join("/");

  return files.has(path) ? path : "";
});

let note = $derived(pageNotes.get(tab.id) ?? text.notesBody);
let completed = $state([false, false, true]);
const saveNote = (event: Event & { currentTarget: HTMLTextAreaElement }) => { pageNotes.set(tab.id, event.currentTarget.value); };

const visit = (url: string, event?: MouseEvent) => {
  event?.preventDefault();

  if (event?.metaKey || event?.button === 1) { host.openLinkTab(url, true); }
  else if (onnavigate) { onnavigate(url); }
  else if (onpreview && !host.snapshot().agentControl && (event?.shiftKey || (tab.isPinned || tab.isBookmarked) && preferences.peekPinnedTabLinks !== "false" && tab.url && new URL(tab.url).hostname.split(".").slice(-2).join(".") !== new URL(url).hostname.split(".").slice(-2).join("."))) { onpreview("peek", url); }
  else { host.navigateTab(tab.id, url); }
};

const openLink = (action: LinkAction) => {
  linkMenu.hidePopover();
  linkTarget?.focus({ preventScroll: true });

  if (action === "peek" || action === "little") { onpreview?.(action, linkURL); }
  else if (action === "copy") { void navigator.clipboard.writeText(linkURL).catch(() => host.showNotice()); }
  else if (action === "split") {
    host.dispatch("splitURL", { side: "right", targetTabId: onnavigate ? host.snapshot().activeTabId : tab.id, url: linkURL });
    onpreviewclose?.();
  } else {
    host.openLinkTab(linkURL, action === "background");

    if (action === "tab") { onpreviewclose?.(); }
  }
};

const showLinkMenu = async (event: (MouseEvent | KeyboardEvent) & { currentTarget: HTMLAnchorElement }, url: string) => {
  event.preventDefault();
  event.stopPropagation();
  linkTarget = event.currentTarget;
  linkURL = url;
  const anchor = linkTarget.getBoundingClientRect();
  const x = event instanceof MouseEvent && event.clientX ? event.clientX : anchor.left;
  const y = event instanceof MouseEvent && event.clientY ? event.clientY : anchor.bottom;
  menuPosition = { x, y };
  await tick();
  linkMenu.showPopover();
  const bounds = linkMenu.getBoundingClientRect();
  menuPosition = { x: Math.max(8, Math.min(x, innerWidth - bounds.width - 8)), y: Math.max(8, Math.min(y, innerHeight - bounds.height - 8)) };
  linkMenu.querySelector("button")?.focus({ preventScroll: true });
};

const pageLink = (url: string) => ({
  href: url,
  onauxclick: (event: MouseEvent) => { if (event.button === 1) { visit(url, event); } },
  onclick: (event: MouseEvent) => visit(url, event),
  oncontextmenu: (event: MouseEvent & { currentTarget: HTMLAnchorElement }) => showLinkMenu(event, url),
  onkeydown: (event: KeyboardEvent & { currentTarget: HTMLAnchorElement }) => {
    if (event.key === "ContextMenu" || event.shiftKey && event.key === "F10") { void showLinkMenu(event, url); }
  },
});

const fileURL = (name: string) => `${repoBase}/${name === "README.md" ? "blob" : "tree"}/main/${encodeURIComponent(name)}`;

const dismissLinkMenu = (event: PointerEvent) => {
  if (linkMenu.matches(":popover-open") && event.target instanceof Node && !linkMenu.contains(event.target)) {
    linkMenu.hidePopover();
  }
};

const linkMenuKey = (event: KeyboardEvent) => {
  if (event.key === "Escape" || event.key === "Tab") {
    event.preventDefault();
    event.stopPropagation();
    linkMenu.hidePopover();
    linkTarget?.focus({ preventScroll: true });

    return;
  }

  const buttons = [...linkMenu.querySelectorAll("button")];
  const focused = linkMenu.querySelector<HTMLButtonElement>("button:focus");
  const current = focused ? buttons.indexOf(focused) : -1;
  let next = current;

  if (event.key === "ArrowDown") { next = (current + 1) % buttons.length; }
  else if (event.key === "ArrowUp") { next = (current + buttons.length - 1) % buttons.length; }
  else if (event.key === "Home") { next = 0; }
  else if (event.key === "End") { next = buttons.length - 1; }
  else { return; }

  event.preventDefault();
  event.stopPropagation();
  buttons[next]?.focus({ preventScroll: true });
};

const search = (event: SubmitEvent) => {
    event.preventDefault();
    const value = query.trim();

    if (!value) {
        return;
    }

    if (/^https?:\/\//iu.test(value)) {visit(value);}
else if (/^(?:\w[\w.-]*\.[a-z]{2,})(?:\/|$)/iu.test(value)) {visit(`https://${value}`);}
else {visit(buildSearchURL(value, preferences.searchEngine));}
};

</script>

<svelte:window onpointerdown={dismissLinkMenu} />

<div class="page" class:terminal-page={kind === "terminal"} style:zoom={zoom} style:height={`${100 / zoom}%`} style:--demo-minimum-font={`${minimumFont}px`} style:font-size={`max(14px, ${minimumFont}px)`}>
  {#if kind === "repo"}
    <div class="repo-top"><img class="repo-mark" src={host.faviconFor(tab.url)} alt="" width="28" height="28" /><b>Alexays <span>/</span> Lilo</b><span class="repo-public">Public</span></div>
    <nav class="repo-nav" aria-label="Lilo">
      <a class:current={repoSection === "code"} {...pageLink(repoBase)}><svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><path d="m7 5-5 5 5 5m6-10 5 5-5 5"/></svg>{text.code}</a>
      <a class:current={repoSection === "issues"} {...pageLink(`${repoBase}/issues`)}><svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="10" cy="10" r="7"/><path d="M10 6v5m0 2v1"/></svg>Issues <span>3</span></a>
      <a class:current={repoSection === "readme"} {...pageLink(`${repoBase}#readme`)}><SettingsIcon name="page" />{text.readme}</a>
    </nav>
    <div class="repo-layout">
      <div>
        {#if repoSection === "issues"}
          <h2>{text.board}</h2>
          {#each [text.issueOne, text.issueTwo, text.issueThree] as issue, index (index)}
            <label class="issue"><input type="checkbox" bind:checked={completed[index]} /><span class:done={completed[index]}>{issue}</span><small>#{index + 1}</small></label>
          {/each}
        {:else if file}
          <a class="back-link" {...pageLink(repoBase)}>‹ {text.files}</a>
          <h2>{file}</h2><pre class="file-content">{file === "README.md" ? `# Lilo\n\n${text.repoBody}` : `${file}/\n\n${text.repoReadme}\n\nSwift · Svelte · WebKit`}</pre>
        {:else}
          {#if repoSection === "code"}
            <div class="repo-toolbar"><span class="branch">⑂ main⌄</span><span>MIT</span><button class="code-button" onclick={() => host.showNotice()}>〈〉 {text.code}⌄</button></div>
            <div class="file-list">
              <div class="commit"><span class="avatar" aria-hidden="true"><SettingsIcon name="person" /></span><b>Alexays</b><span>fix(ui): a little more polish</span><small>268 commits</small></div>
              {#each files as name (name)}
                <a {...pageLink(fileURL(name))}><span class="folder-icon"><SettingsIcon name={name === "README.md" ? "page" : "folder"} /></span><span>{name}</span><small>{name === "site" ? "Your internet, in bloom" : "A little better, every release"}</small></a>
              {/each}
            </div>
          {/if}
          <article class="readme"><span class="eyebrow">{text.readme}</span><div class="flower"><Fleuron size={48} /></div><h1>{text.repoReadme}</h1><p>{text.repoBody}</p><div class="repo-badges"><span>WebKit</span><span>Swift</span><span>Svelte</span><span>MIT</span></div></article>
        {/if}
      </div>
      <aside><h3>{text.about}</h3><p>{text.repoAbout}</p><a class="repo-home-link" {...pageLink("https://getlilo.app")}>↗ getlilo.app</a><div class="repo-topics"><span>macOS</span><span>webkit</span><span>open-source</span></div><p class="repo-stat">☆ 3 stars<br />⑂ 1 fork<br />♡ MIT license</p></aside>
    </div>
  {:else if kind === "travel"}
    <div class="travel-cover"><span class="travel-site">SLOW TRAVEL</span><span class="sun" aria-hidden="true"></span><div class="hills" aria-hidden="true"></div><div class="travel-heading"><span>{text.articleMeta}</span><h1>{text.article}</h1><p>{text.articleSubtitle}</p></div></div>
    <article class="travel-body"><p>{text.articleBody}</p><div class="days">{#each [text.dayOne, text.dayTwo, text.dayThree] as title, index (index)}<button class:selected={day === index} onclick={() => { day = index; }}><span>{text.dayLabel} 0{index + 1}</span><b>{title}</b></button>{/each}</div><h2>{[text.dayOne, text.dayTwo, text.dayThree][day]}</h2><p>{text.articleBody}</p><nav class="related-links" aria-label={text.quickLinks}><a {...pageLink("https://notes.example.com/travel")}>{text.notes}</a><a {...pageLink("https://radio.example.com/late-night")}>{text.playlist}</a></nav></article>
  {:else if kind === "notes"}
    <article class="notes"><span class="eyebrow">NOTES</span><h1>{text.notes}</h1><textarea aria-label={text.editor} bind:value={note} oninput={saveNote} placeholder={text.notePlaceholder}></textarea><small>{text.saved}</small></article>
  {:else if kind === "music"}
    <article class="music"><div class="album" aria-hidden="true"><span>♫</span><small>AFTER HOURS</small></div><span class="eyebrow">RADIO</span><h1>{text.playlist}</h1><p>{text.playlistSubtitle}</p><button class="play-button" aria-label={playing ? text.pause : text.play} aria-pressed={playing} onclick={() => { playing = !playing; }}>{playing ? "Ⅱ" : "▶"}</button><ol>{#each [text.trackOne, text.trackTwo, text.trackThree] as title, index (index)}<li><button class:track-selected={track === index} onclick={() => { track = index; playing = true; }}><span>0{index + 1}</span><b>{title}</b><small>{["3:42", "4:18", "5:06"][index]}</small></button></li>{/each}</ol></article>
  {:else if kind === "board"}
    <article class="board"><span class="eyebrow">STUDIO / {text.projects}</span><h1>{text.board}</h1><p>{text.boardSubtitle}</p>{#each [text.issueOne, text.issueTwo, text.issueThree] as issue, index (index)}<label class="issue"><input type="checkbox" bind:checked={completed[index]} /><span class:done={completed[index]}>{issue}</span><small>{completed[index] ? text.done : text.todo}</small></label>{/each}</article>
  {:else if kind === "terminal"}
    {#await import("./DemoTerminal.svelte") then terminal}
      <terminal.default {tab} {host} {locale} />
    {/await}
  {:else if kind === "mcp"}
    {#await import("./DemoMcp.svelte") then mcp}
      <mcp.default {host} {locale} />
    {/await}
  {:else if kind === "launch"}
    {#await import("./DemoLaunch.svelte")}
      <p data-page-loading="true" role="status">{text.projectLoading}</p>
    {:then launch}
      <launch.default tabId={tab.id} {locale} />
    {/await}
  {:else if kind === "project"}
    {#await import("./DemoProject.svelte")}
      <p data-page-loading="true" role="status">{text.projectLoading}</p>
    {:then project}
      <project.default {host} {locale} />
    {/await}
  {:else}
    <article class="start"><div class="flower"><Fleuron size={76} /></div><span class="eyebrow">{kind === "sample" ? new URL(tab.url).hostname : "LILO"}</span><h1>{kind === "home" ? text.welcome : text.samplePage}</h1><p>{kind === "home" ? text.welcomeSubtitle : text.samplePageBody}</p><form class="search" onsubmit={search}><input aria-label={text.searchPlaceholder} placeholder={text.searchPlaceholder} bind:value={query} /><button aria-label={text.search} type="submit">↵</button></form><div class="quick-links" aria-label={text.quickLinks}>{#each samples as sample (sample.url)}<a {...pageLink(sample.url)}><i><img src={host.faviconFor(sample.url)} alt="" width="32" height="32" /></i><span>{sample.title}</span></a>{/each}</div><button class="settings-link" onclick={() => host.emit("openSettings", {})}>{text.settings}</button></article>
  {/if}
</div>

<!-- Manual dismissal prevents WebKit from closing the menu on the opening right-button release. -->
<div class="page-link-menu" popover="manual" role="menu" aria-label={text.linkMenu} tabindex="-1" bind:this={linkMenu} style:left={`${menuPosition.x}px`} style:top={`${menuPosition.y}px`} onkeydown={linkMenuKey}>
  {#each linkActions as item (item.action)}<button type="button" role="menuitem" onclick={() => openLink(item.action)}>{item.label}</button>{/each}
</div>

<style>
  .page { height: 100%; overflow: auto; background: var(--bg-primary); color: var(--text-primary); font: 14px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  button, input, textarea { font: inherit; }
  a { cursor: pointer; text-decoration: none; }
  button { cursor: pointer; }
  button:focus-visible, a:focus-visible, textarea:focus-visible, input:focus-visible { outline: var(--focus-outline); outline-offset: 3px; }
  h1 { font-size: max(32px, var(--demo-minimum-font, 0px)); line-height: 1.15; letter-spacing: -1px; margin: 10px 0 18px; }
  h2 { font-size: max(22px, var(--demo-minimum-font, 0px)); margin: 22px 0 12px; } h3 { font-size: max(15px, var(--demo-minimum-font, 0px)); margin: 0 0 10px; }
  p { margin: 0 0 20px; } .eyebrow { font-size: max(10px, var(--demo-minimum-font, 0px)); letter-spacing: 1.8px; color: var(--text-secondary); font-weight: 600; }
  .repo-top { display: flex; gap: 12px; align-items: center; padding: 18px 24px 10px; background: var(--bg-hover); }
  .repo-mark { display: block; border-radius: 50%; } .repo-top b { font-size: max(16px, var(--demo-minimum-font, 0px)); } .repo-top b span { color: var(--text-muted); padding: 0 5px; }
  .repo-public { font-size: max(11px, var(--demo-minimum-font, 0px)); padding: 0 8px; border: 1px solid var(--border); border-radius: 20px; color: var(--text-secondary); }
  .repo-nav { display: flex; gap: 16px; padding: 0 24px; border-bottom: 1px solid var(--border); background: var(--bg-hover); }
  .repo-nav a { display: inline-flex; align-items: center; gap: 7px; background: none; color: var(--text-secondary); padding: 12px 4px; border: 0; border-bottom: 2px solid transparent; font-size: max(12px, var(--demo-minimum-font, 0px)); }
  .repo-nav a.current { color: var(--text-primary); border-bottom-color: #d88870; } .repo-nav a span { margin-left: 5px; padding: 1px 5px; background: var(--bg-hover); border-radius: 8px; }
  .repo-layout { display: grid; grid-template-columns: minmax(0, 1fr) 175px; gap: 24px; padding: 24px; }
  .repo-layout aside { padding-top: 4px; font-size: max(13px, var(--demo-minimum-font, 0px)); } .repo-home-link { text-decoration: none; color: #527bb4; font: inherit; font-weight: 500; border: 0; background: none; padding: 0; }
  .repo-toolbar { display: flex; gap: 15px; align-items: center; font-size: max(11px, var(--demo-minimum-font, 0px)); margin-bottom: 14px; } .branch { background: var(--bg-hover); border: 1px solid var(--border); border-radius: 6px; padding: 3px 10px; }
  .code-button { margin-left: auto; border: 0; border-radius: 6px; background: #347848; color: white; padding: 4px 14px; font-size: max(11px, var(--demo-minimum-font, 0px)); }
  .file-list { border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
  .commit { display: flex; align-items: center; gap: 8px; padding: 10px 12px; background: var(--bg-hover); font-size: max(10px, var(--demo-minimum-font, 0px)); } .commit > span:not(.avatar) { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
  .commit small { margin-left: auto; white-space: nowrap; font-size: max(9px, var(--demo-minimum-font, 0px)); } .avatar { display: inline-flex; align-items: center; justify-content: center; flex: none; background: var(--bg-active); color: var(--text-secondary); width: 18px; height: 18px; border-radius: 50%; }
  .file-list > a { border: 0; border-top: 1px solid var(--border); padding: 7px 12px; width: 100%; display: flex; align-items: center; gap: 10px; color: var(--text-primary); background: none; text-align: left; font-size: max(11px, var(--demo-minimum-font, 0px)); }
  .file-list > a:hover { background: var(--bg-hover); } .file-list small { margin-left: auto; max-width: 48%; text-overflow: ellipsis; overflow: hidden; white-space: nowrap; color: var(--text-muted); font-size: max(9px, var(--demo-minimum-font, 0px)); }
  .folder-icon { display: inline-flex; flex: none; color: #8194ae; } .folder-icon :global(svg), .repo-nav :global(.settings-icon-svg), .avatar :global(svg) { width: 16px; height: 16px; } .repo-topics, .repo-badges { display: flex; flex-wrap: wrap; gap: 5px; margin: 16px 0; } .repo-topics span, .repo-badges span { padding: 2px 9px; border-radius: 12px; background: var(--accent-tint-14); color: var(--accent-ink); font-size: max(10px, var(--demo-minimum-font, 0px)); }
  .repo-stat { font-size: max(11px, var(--demo-minimum-font, 0px)); color: var(--text-secondary); line-height: 2; } .readme { padding: 18px 20px 30px; margin-top: 20px; border: 1px solid var(--border); border-radius: 8px; } .readme h1 { font-size: max(24px, var(--demo-minimum-font, 0px)); } .readme p { font-size: max(13px, var(--demo-minimum-font, 0px)); }
  .flower { margin: 25px 0 20px; } .readme .flower { margin: 22px 0 10px; }
  .file-content { white-space: pre-wrap; font: 13px/1.8 ui-monospace, monospace; padding: 20px; background: var(--bg-hover); border-radius: 8px; } .back-link { border: 0; background: none; padding: 0; color: var(--accent-ink); }
  .travel-cover { position: relative; overflow: hidden; min-height: 310px; color: #352c3c; background: linear-gradient(145deg, #f6d9bd 5%, #e8bdbb 50%, #b8b7dc); }
  .travel-site { position: absolute; left: 32px; top: 24px; font-size: max(11px, var(--demo-minimum-font, 0px)); letter-spacing: 3px; font-weight: 600; } .sun { position: absolute; width: 90px; height: 90px; border-radius: 50%; background: #fae8cc; right: 90px; top: 60px; }
  .hills { position: absolute; width: 75%; height: 240px; border-radius: 50% 70% 0 0; background: #b29db6; right: -100px; bottom: -140px; transform: rotate(-15deg); box-shadow: -120px 40px 0 #c4aaa7; }
  .travel-heading { position: relative; max-width: 500px; padding: 120px 32px 28px; } .travel-heading > span { font-size: max(9px, var(--demo-minimum-font, 0px)); letter-spacing: 1.5px; } .travel-heading h1 { font-family: ui-serif, Georgia, serif; font-size: max(44px, var(--demo-minimum-font, 0px)); font-weight: 500; max-width: 10ch; } .travel-heading p { font-size: max(13px, var(--demo-minimum-font, 0px)); }
  .travel-body { max-width: 700px; margin: auto; padding: 28px 32px; font-family: ui-serif, Georgia, serif; font-size: max(17px, var(--demo-minimum-font, 0px)); } .days { display: grid; grid-template-columns: repeat(3, 1fr); gap: 9px; margin: 26px 0; }
  .days button { background: var(--bg-hover); border: 1px solid transparent; border-radius: 9px; text-align: left; padding: 14px 10px; color: var(--text-primary); } .days button.selected { border-color: #bb9fbd; background: var(--accent-tint-14); } .days span { display: block; font: 9px/2 -apple-system, sans-serif; text-transform: uppercase; letter-spacing: 1px; color: var(--text-secondary); } .days b { font-size: max(13px, var(--demo-minimum-font, 0px)); font-weight: 500; }
  .notes, .board { max-width: 650px; margin: auto; padding: 60px 44px; } .notes textarea { display: block; width: 100%; min-height: 320px; resize: vertical; color: var(--text-primary); background: transparent; border: 0; border-top: 1px solid var(--border); padding: 22px 0; font: 18px/1.8 ui-serif, Georgia, serif; } .notes small { color: var(--text-muted); font-size: max(11px, var(--demo-minimum-font, 0px)); }
  .issue { display: flex; align-items: center; gap: 12px; border-bottom: 1px solid var(--border); padding: 16px 0; font-size: max(13px, var(--demo-minimum-font, 0px)); cursor: pointer; } .issue input { accent-color: var(--accent); width: 16px; height: 16px; } .issue small { margin-left: auto; color: var(--text-muted); font-size: max(10px, var(--demo-minimum-font, 0px)); } .issue .done { text-decoration: line-through; color: var(--text-secondary); }
  .music { max-width: 480px; margin: auto; padding: 38px 36px; text-align: center; } .album { position: relative; display: grid; place-content: center; gap: 10px; width: 160px; aspect-ratio: 1; margin: 0 auto 25px; background: radial-gradient(ellipse at 70% 20%, #d8a8b9, transparent 60%), linear-gradient(145deg, #5e568b, #333b58 70%); color: #f1e8fa; border-radius: 8px; box-shadow: 0 16px 28px -14px #29203c80; } .album > span { font-size: max(50px, var(--demo-minimum-font, 0px)); } .album small { font-size: max(8px, var(--demo-minimum-font, 0px)); letter-spacing: 3px; } .music h1 { margin-bottom: 10px; font-size: max(27px, var(--demo-minimum-font, 0px)); } .music p { color: var(--text-secondary); font-size: max(12px, var(--demo-minimum-font, 0px)); }
  .play-button { width: 40px; height: 40px; border: 0; border-radius: 50%; background: var(--text-primary); color: var(--bg-primary); } .music ol { list-style: none; padding: 0; margin: 24px 0 0; } .music li button { display: flex; gap: 18px; align-items: center; width: 100%; border: 0; border-radius: 6px; padding: 12px; background: transparent; color: var(--text-secondary); font-size: max(12px, var(--demo-minimum-font, 0px)); } .music li button.track-selected { background: var(--bg-hover); color: var(--accent-ink); } .music li small { margin-left: auto; font-size: max(10px, var(--demo-minimum-font, 0px)); }
  .start { display: grid; justify-items: center; text-align: center; max-width: 620px; margin: auto; padding: 65px 36px; } .start h1 { font-size: max(31px, var(--demo-minimum-font, 0px)); margin-bottom: 12px; } .start p { max-width: 46ch; color: var(--text-secondary); font-size: max(13px, var(--demo-minimum-font, 0px)); } .start .flower { margin-top: 0; }
  .search { display: flex; width: 100%; max-width: 430px; background: var(--bg-hover); border: 1px solid var(--border); border-radius: 12px; padding: 5px 8px 5px 16px; margin: 8px 0 30px; box-shadow: 0 4px 12px #00000005; } .search input { flex: 1; width: 0; padding: 7px 0; background: transparent; border: 0; color: var(--text-primary); font-size: max(12px, var(--demo-minimum-font, 0px)); } .search button { background: transparent; color: var(--text-secondary); border: 0; padding: 0 8px; }
  .quick-links { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; width: 100%; max-width: 430px; } .quick-links a { text-decoration: none; display: grid; justify-items: center; gap: 9px; border: 0; background: transparent; color: var(--text-secondary); font-size: max(10px, var(--demo-minimum-font, 0px)); } .quick-links i { display: grid; place-items: center; border-radius: 12px; width: 43px; height: 43px; background: var(--bg-hover); } .quick-links img { display: block; border-radius: 8px; } .settings-link { margin-top: 36px; font-size: max(11px, var(--demo-minimum-font, 0px)); background: none; color: var(--text-secondary); border: 0; padding: 8px; }
  .related-links { display: flex; flex-wrap: wrap; gap: 12px 24px; margin-top: 28px; }
  .related-links a { color: var(--accent-ink); text-underline-offset: 3px; }
  .page-link-menu { position: fixed; inset: auto; margin: 0; padding: 5px; min-width: 210px; max-width: calc(100vw - 16px); border: 1px solid var(--chrome-overlay-border, var(--border)); border-radius: 9px; background: var(--chrome-floating-surface, var(--bg-elevated)); color: var(--text-primary); box-shadow: var(--chrome-floating-shadow, 0 8px 25px #0003); font: 12px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; }
  .page-link-menu:popover-open { display: grid; }
  .page-link-menu button { border: 0; border-radius: 4px; padding: 5px 10px; background: transparent; color: inherit; text-align: left; font: inherit; }
  .page-link-menu button:hover, .page-link-menu button:focus-visible { background: var(--accent); color: var(--accent-text); outline: none; }
  .terminal-page { background: #181923; color: #e4e1f3; }
  @media (max-width: 600px) { .repo-layout { grid-template-columns: minmax(0, 1fr); } .repo-layout aside { display: none; } .notes, .board { padding: 35px 24px; } .start { padding: 45px 20px; } .repo-layout { padding: 16px; } }
</style>
