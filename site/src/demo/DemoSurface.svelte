<script lang="ts">
import { tick, untrack } from "svelte";
import type { DemoHost, DemoSnapshot } from "./host";
import { demoCopy } from './world';
import type { DemoLocale } from './world';
import DemoPage from "./DemoPage.svelte";
import DemoExplore from "./DemoExplore.svelte";
import DemoPreview from "./DemoPreview.svelte";
import Fleuron from "../../../lilo-ui/src/components/onboarding/Fleuron.svelte";
import BottomConfirmSheet from "../../../lilo-ui/src/components/ui/BottomConfirmSheet.svelte";
import type { DemoFeatureId } from "../lib/i18n.ts";
import { buildContextMenu, folderTabCount } from "./context-menu.ts";
import type { ContextAction, ContextMenuItem } from "./context-menu.ts";
import { nativeCopy } from "./native-copy.ts";

let { host, expand, onfeature, onstatechange }: {
    host: DemoHost;
    expand: () => void;
    onfeature: (id: DemoFeatureId) => void;
    onstatechange?: () => void;
} = $props();

let snapshot = $state<DemoSnapshot>(untrack(() => host.snapshot()));
let windowState = $state<"open" | "closed" | "minimized">("open");
let menuElement: HTMLDivElement | undefined = $state();
let submenuElement: HTMLDivElement | undefined = $state();
let menuPosition = $state({ x: 8, y: 8 });
let submenuPosition = $state({ x: 8, y: 8 });
let submenuKey = $state("");
let menuOrigin: HTMLElement | null = null;
let contextEvent: MouseEvent | null = null;
let confirmation = $state<{ kind: "folder" | "space"; id: string; title: string; message: string } | null>(null);
let reloads = $state<Record<string, number>>({});
let exploring = $state(false);
let preview = $state<{ mode: "peek" | "little"; url: string } | null>(null);
let previewWindow: ReturnType<typeof DemoPreview> | undefined = $state();
const locale = $derived(snapshot.settings.locale === "fr" ? "fr" : "en");
const text = $derived(demoCopy(locale));
const nativeText = $derived(nativeCopy(locale));
const panes = $derived(snapshot.splitIds.length > 1 ? snapshot.splitIds.flatMap((id) => snapshot.tabs.filter((tab) => tab.id === id)) : snapshot.tabs.filter((tab) => tab.id === snapshot.activeTabId));
const menuItems = $derived(buildContextMenu(snapshot, nativeText));
const submenuItem = $derived(menuItems.find((entry): entry is ContextMenuItem => entry.kind === "item" && entry.key === submenuKey));
const menuIdentity = $derived(snapshot.menu ? `${snapshot.menu.kind}:${snapshot.menu.id}:${snapshot.menu.x}:${snapshot.menu.y}` : "");
export const refresh = () => { snapshot = host.snapshot(); };
export const reopen = () => { windowState = "open"; };
export const minimize = () => { windowState = "minimized"; };
export const closeWindow = () => { windowState = "closed"; };
export const hasPreview = () => preview !== null;
export const openAsTab = () => { previewWindow?.expand(); };
export const reload = () => { reloads = { ...reloads, [snapshot.activeTabId]: (reloads[snapshot.activeTabId] ?? 0) + 1 }; };
export const showFeatures = () => { exploring = true; };
export const showPreview = (mode: "peek" | "little", url: string) => { preview = { mode, url }; };

$effect(() => {
    void preview;
    void windowState;
    onstatechange?.();
});

export const closeTransient = () => {
    const open = exploring || preview !== null || confirmation !== null || snapshot.menu !== null;
    exploring = false;
    preview = null;
    confirmation = null;

    if (snapshot.menu) { host.closeMenu(); }

    return open;
};

const activatePane = (id: string) => {
    if (snapshot.activeTabId !== id) {
        host.dispatch("switchTab", { id });
    }
};

const paneStyle = (id: string) => {
    if (panes.length < 2) { return ""; }

    const frame = snapshot.splitPaneFrames.find((candidate) => candidate.tabId === id);

    if (!frame) { return ""; }

    const left = frame.x > 0 ? 4 : 0;
    const top = frame.y > 0 ? 4 : 0;
    const right = frame.x + frame.width < 0.99999 ? 4 : 0;
    const bottom = frame.y + frame.height < 0.99999 ? 4 : 0;

    return `left:calc(${frame.x * 100}% + ${left}px);top:calc(${frame.y * 100}% + ${top}px);width:calc(${frame.width * 100}% - ${left + right}px);height:calc(${frame.height * 100}% - ${top + bottom}px)`;
};

$effect(() => {
    const app = document.querySelector<HTMLElement>("#app");

    if (app) {
        app.hidden = windowState !== "open";
    }

    host.emit("windowFocusChanged", { focused: windowState === "open" });
    host.emit("powerModeChanged", { constrained: windowState !== "open" });
});

$effect(() => {
    const identity = menuIdentity;
    submenuKey = "";

    if (!identity) { return; }

    const menu = untrack(() => snapshot.menu);

    if (!menu) { return; }

    const active = document.activeElement;

    if (!contextEvent?.defaultPrevented && active instanceof HTMLElement && !active.closest(".native-menu")) { menuOrigin = active; }

    contextEvent = null;
    menuPosition = { x: menu.x, y: menu.y };

    void tick().then(() => {
        if (menuIdentity !== identity || !menuElement) { return null; }

        const rect = menuElement.getBoundingClientRect();
        menuPosition = {
            x: Math.max(8, Math.min(menu.x, innerWidth - rect.width - 8)),
            y: Math.max(8, Math.min(menu.y, innerHeight - rect.height - 8)),
        };
        menuElement.querySelector<HTMLButtonElement>("button:not(:disabled)")?.focus({ preventScroll: true });

        return null;
    });
});

const rememberMenuOrigin = (event: MouseEvent) => {
    if (event.target instanceof Element && !event.target.closest(".native-menu")) {
        menuOrigin = event.target.closest<HTMLElement>("button, [tabindex]");
        contextEvent = event;
    }
};

const restoreMenuFocus = () => {
    const target = menuOrigin?.isConnected ? menuOrigin : document.querySelector<HTMLElement>(`[data-tab-id="${CSS.escape(snapshot.activeTabId)}"]`);
    target?.focus({ preventScroll: true });
};

const dismissMenu = (restoreFocus = false) => {
    submenuKey = "";
    host.closeMenu();

    if (restoreFocus) { void tick().then(restoreMenuFocus); }
};

const dismissOutside = (event: PointerEvent) => {
    if (snapshot.menu && !(event.target instanceof Element && event.target.closest(".native-menu"))) {
        dismissMenu();
    }
};

const openSubmenu = (entry: ContextMenuItem, anchor: HTMLButtonElement, focus = false) => {
    if (!entry.children || entry.disabled) { return; }

    const rect = anchor.getBoundingClientRect();
    submenuKey = entry.key;
    submenuPosition = { x: rect.right + 2, y: rect.top - 5 };
    void tick().then(() => {
        if (submenuKey !== entry.key || !submenuElement) { return null; }

        const box = submenuElement.getBoundingClientRect();
        submenuPosition = {
            x: rect.right + box.width + 10 > innerWidth ? Math.max(8, rect.left - box.width - 2) : rect.right + 2,
            y: Math.max(8, Math.min(rect.top - 5, innerHeight - box.height - 8)),
        };

        if (focus) { submenuElement.querySelector<HTMLButtonElement>("button:not(:disabled)")?.focus({ preventScroll: true }); }

        return null;
    });
};

const enabledMenuButtons = (layer: HTMLDivElement | undefined) =>
    [...(layer?.querySelectorAll<HTMLButtonElement>("button:not(:disabled)") ?? [])];

const nextMenuIndex = (event: KeyboardEvent, items: HTMLButtonElement[], index: number) => {
    if (event.key === "ArrowDown") { return (index + 1) % items.length; }

    if (event.key === "ArrowUp") { return index < 0 ? items.length - 1 : (index + items.length - 1) % items.length; }

    if (event.key === "Home") { return 0; }

    if (event.key === "End") { return items.length - 1; }

    if (event.key.length !== 1 || event.key === " " || event.metaKey || event.ctrlKey || event.altKey) { return -1; }

    const rotated = [...items.slice(index + 1), ...items.slice(0, index + 1)];
    const match = rotated.find((button) => button.dataset.label?.toLocaleLowerCase(locale).startsWith(event.key.toLocaleLowerCase(locale)));

    return match ? items.indexOf(match) : -1;
};

const handleMenuExit = (event: KeyboardEvent, inSubmenu: boolean) => {
    if (inSubmenu && ["ArrowLeft", "Escape"].includes(event.key)) {
        event.preventDefault();
        event.stopImmediatePropagation();
        menuElement?.querySelector<HTMLButtonElement>(`[data-menu-key="${  CSS.escape(submenuKey)  }"]`)?.focus({ preventScroll: true });
        submenuKey = "";

        return true;
    }

    if (["Escape", "Tab"].includes(event.key)) {
        event.preventDefault();
        event.stopImmediatePropagation();
        dismissMenu(true);

        return true;
    }

    return false;
};

const openFocusedSubmenu = (event: KeyboardEvent, active: Element | null) => {
    if (!(active instanceof HTMLButtonElement)) { return; }

    const entry = menuItems.find((candidate): candidate is ContextMenuItem => candidate.kind === "item" && candidate.key === active.dataset.menuKey);

    if (entry?.children) {
        event.preventDefault();
        event.stopImmediatePropagation();
        openSubmenu(entry, active, true);
    }
};

const menuKeydown = (event: KeyboardEvent) => {
    if (!snapshot.menu) { return; }

    const active = document.activeElement;
    const inSubmenu = Boolean(active instanceof Element && active.closest(".context-submenu"));

    if (handleMenuExit(event, inSubmenu)) { return; }

    if (event.key === "ArrowRight" && !inSubmenu) {
        openFocusedSubmenu(event, active);

        return;
    }

    const items = enabledMenuButtons(inSubmenu ? submenuElement : menuElement);

    if (!items.length) { return; }

    const index = active instanceof HTMLButtonElement ? items.indexOf(active) : -1;
    const next = nextMenuIndex(event, items, index);

    if (next >= 0) {
        event.preventDefault();
        event.stopImmediatePropagation();

        if (!inSubmenu) { submenuKey = ""; }

        items[next]?.focus({ preventScroll: true });
    }
};

const createContextItem = (action: Extract<ContextAction, { type: "newItem" }>) => {
    if (snapshot.activeSpaceId !== action.spaceId) { host.dispatch("switchSpace", { id: action.spaceId }); }

    if (action.kind === "folder") { host.createFolder(nativeText("New Folder")); }
    else { host.dispatch(action.kind === "terminal" ? "newTerminal" : "createTab", {}); }
};

const showDeletionConfirmation = (action: Extract<ContextAction, { type: "delete" }>) => {
    const folder = snapshot.folders.find((candidate) => candidate.id === action.id);
    const space = snapshot.spaces.find((candidate) => candidate.id === action.id);

    if (action.kind === "folder" ? !folder : !space) { return; }

    const count = action.kind === "folder" ? folderTabCount(snapshot, action.id) : 0;
    const name = folder?.name ?? space?.name ?? "";
    let title = nativeText("Delete %@?", name);

    if (count) {
        const tabs = count === 1 ? nativeText("1 tab") : nativeText("%d tabs", count);
        title = nativeText("Delete %@ and %@?", name, tabs);
    }

    confirmation = {
        id: action.id,
        kind: action.kind,
        message: action.kind === "folder" ? nativeText("This cannot be undone.") : nativeText("The space and all its tabs are deleted permanently."),
        title,
    };
};

const act = (action: ContextAction | undefined) => {
    if (!action) { return; }

    dismissMenu();

    switch (action.type) {
        case "command": { host.dispatch(action.command.name, action.command.payload); break;
        }

        case "event": { host.emit(action.event.name, action.event.payload); break;
        }

        case "editTab": { host.emit("beginTabEdit", { homeURL: host.getTabHomeURL(action.id), id: action.id }); break;
        }

        case "host": { host[action.method](action.id); break;
        }

        case "newItem": { createContextItem(action); break; }

        case "delete": { showDeletionConfirmation(action); break; }

        case "stopAgents": { host.stopAgents(); break;
        }

        default: { break; }
    }

    void tick().then(() => {
        if (document.activeElement === document.body) { restoreMenuFocus(); }

        return null;
    });
};

const confirmDeletion = () => {
    const pending = confirmation;
    confirmation = null;

    if (pending?.kind === "folder") { host.deleteFolderConfirmed(pending.id); }
    else if (pending) { host.dispatch("deleteSpace", { id: pending.id }); }

    void tick().then(restoreMenuFocus);
};

const cancelDeletion = () => {
    confirmation = null;
    void tick().then(restoreMenuFocus);
};

export const requestFolderDeletion = (id: string) => {
    menuOrigin = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    act({ id, kind: "folder", type: "delete" });
};

</script>

<svelte:window onpointerdown={dismissOutside} onkeydown={menuKeydown} oncontextmenucapture={rememberMenuOrigin} />

{#snippet menuRow(entry: ContextMenuItem, child: boolean)}
  <button
    role={entry.checked === undefined ? "menuitem" : "menuitemradio"}
    aria-checked={entry.checked}
    aria-haspopup={entry.children ? "menu" : undefined}
    aria-expanded={entry.children ? submenuKey === entry.key : undefined}
    aria-controls={entry.children && submenuKey === entry.key ? "demo-context-submenu" : undefined}
    data-menu-key={entry.key}
    data-label={entry.label}
    tabindex="-1"
    disabled={entry.disabled}
    title={entry.macOnly ? text.exploreMacNote : undefined}
    onpointerenter={(event) => {
      if (entry.disabled) { return; }
      event.currentTarget.focus({ preventScroll: true });
      if (entry.children) { openSubmenu(entry, event.currentTarget); }
      else if (!child) { submenuKey = ""; }
    }}
    onclick={(event) => entry.children ? openSubmenu(entry, event.currentTarget, true) : act(entry.action)}
  >
    <span class="menu-check" aria-hidden="true">{entry.checked ? "✓" : ""}</span>
    <span class="menu-label" style:padding-left={`${(entry.depth ?? 0) * 12}px`}>{entry.label}</span>
    {#if entry.macOnly}<span class="menu-mac">{text.exploreMac}</span>{/if}
    {#if entry.children}<span class="menu-chevron" aria-hidden="true">›</span>{/if}
  </button>
{/snippet}

{#if windowState === "open"}
  <div class="traffic-lights" aria-label="Lilo">
    <button class="close" aria-label={text.closeWindow} onclick={() => { windowState = "closed"; }}><span>×</span></button>
    <button class="minimize" aria-label={text.minimizeWindow} onclick={() => { windowState = "minimized"; }}><span>−</span></button>
    <button class="expand" aria-label={text.expandWindow} onclick={expand}><span>↗</span></button>
  </div>
  <div
    class="sample-content"
    onpointerdown={() => host.emit("contentInteraction", { isMouseDown: true })}
    role="region"
    aria-label={snapshot.tabs.find((tab) => tab.id === snapshot.activeTabId)?.title ?? "Lilo"}
    tabindex="-1"
  >
    {#if snapshot.splitIds.length > 1}
      <button class="close-split" aria-label={text.closeSplit} onclick={() => host.dispatch("closeSplitView", {})}>×</button>
    {/if}
    {#each panes as tab (tab.id)}
      <div class="sample-pane" class:split-pane={panes.length > 1} class:split-focused={panes.length > 1 && snapshot.activeTabId === tab.id} class:agent-controlled={snapshot.agentControl?.tabId === tab.id} data-sample-tab={tab.id} style={paneStyle(tab.id)} role="region" aria-label={tab.title} tabindex="-1" onpointerdown={() => activatePane(tab.id)} onfocusin={() => activatePane(tab.id)}>
        {#key reloads[tab.id] ?? 0}
          <DemoPage {tab} {host} settings={snapshot.settings} locale={locale as DemoLocale} onpeek={(url) => showPreview("peek", url)} />
        {/key}
        {#if snapshot.agentControl?.tabId === tab.id}
          <div class="agent-frame" aria-hidden="true"><span>{text.agentControls}</span></div>
          {#if snapshot.agentControl.pointer}
            <div class="agent-cursor" class:pressed={snapshot.agentControl.pointer.pressed} style:left={`${snapshot.agentControl.pointer.x}px`} style:top={`${snapshot.agentControl.pointer.y}px`} aria-hidden="true">
              <svg viewBox="0 0 22 26"><path d="M3 2V21L8.2 16.2L11.5 23.6L14.8 22.1L11.5 14.9L18.5 14.6Z" /></svg><span>Codex</span>
            </div>
          {/if}
        {/if}
      </div>
    {/each}
  </div>
{:else}
  <div class="restore-window"><Fleuron size={84} /><p>{windowState === "closed" ? text.windowClosed : text.windowMinimized}</p><button onclick={reopen}>{text.reopen}</button></div>
{/if}

{#if snapshot.menu && menuItems.length}
  <div
    class="native-menu"
    role="menu"
    aria-label={text.menu}
    tabindex="-1"
    bind:this={menuElement}
    style:left={`${menuPosition.x}px`}
    style:top={`${menuPosition.y}px`}
  >
    {#each menuItems as entry}
      {#if entry.kind === "separator"}<hr />{:else}{@render menuRow(entry, false)}{/if}
    {/each}
  </div>
  {#if submenuItem?.children}
    <div
      class="native-menu context-submenu"
      id="demo-context-submenu"
      role="menu"
      aria-label={submenuItem.label}
      tabindex="-1"
      bind:this={submenuElement}
      style:left={`${submenuPosition.x}px`}
      style:top={`${submenuPosition.y}px`}
    >
      {#each submenuItem.children as entry}
        {#if entry.kind === "separator"}<hr />{:else}{@render menuRow(entry, true)}{/if}
      {/each}
    </div>
  {/if}
{/if}

<div class="demo-confirmation">
  <BottomConfirmSheet
    visible={confirmation !== null}
    title={confirmation?.title ?? ""}
    message={confirmation?.message ?? ""}
    confirmLabel={nativeText("Delete")}
    cancelLabel={nativeText("Cancel")}
    confirmAction={confirmDeletion}
    cancelAction={cancelDeletion}
  />
</div>

{#if snapshot.notice}
  <div class="notice" role="status"><span>{snapshot.notice}</span><button aria-label={text.closeNotice} onclick={() => host.clearNotice()}>×</button></div>
{/if}

{#if exploring}<DemoExplore locale={locale as DemoLocale} onclose={() => { exploring = false; }} onselect={(id) => { exploring = false; onfeature(id); }} />{/if}
{#if preview}<DemoPreview bind:this={previewWindow} {host} locale={locale as DemoLocale} mode={preview.mode} url={preview.url} onclose={() => { preview = null; }} />{/if}

<style>
  :global(::highlight(demo-find-results)) { background: #f4d97a; color: #242033; }
  :global(::highlight(demo-find-current)) { background: #eea352; color: #242033; }
  /* Stands in for the native window frame; outranks lilo-ui's transparent `html, body`, which loads later. */
  :global(html body) { background: var(--sidebar-bg); }
  /* The demo sits in a page that scrolls: the sidebar must hand vertical wheel back to it. */
  :global(#app .space-track), :global(#app .space-scroll) { overscroll-behavior-y: auto; }
  .traffic-lights { position: fixed; left: 17px; top: 14px; z-index: 1000; display: flex; gap: 8px; }
  :global(html[data-tab-position="left"]) .traffic-lights { top: 20px; }
  .traffic-lights button { border: 0; width: 12px; height: 12px; border-radius: 50%; padding: 0; display: grid; place-items: center; font: 12px/1 -apple-system, sans-serif; color: #412d28; cursor: pointer; box-shadow: inset 0 0 0 0.5px #00000012; }
  .traffic-lights span { opacity: 0; } .traffic-lights:hover span, .traffic-lights button:focus-visible span { opacity: 1; }
  .traffic-lights button:focus-visible { outline: var(--focus-outline); outline-offset: 3px; }
  .close { background: #ff6058; } .minimize { background: #ffbd2e; } .expand { background: #28c840; }
  .sample-content { position: fixed; top: var(--chrome-content-top); right: var(--chrome-content-right); bottom: var(--chrome-content-bottom); left: var(--chrome-content-left); display: flex; gap: 6px; border-radius: 10px; overflow: hidden; background: var(--sidebar-bg); outline: 0; }
  .sample-pane { position: relative; flex: 1; min-width: 0; min-height: 0; height: 100%; border-radius: 8px; overflow: hidden; }
  .sample-pane.split-pane { position: absolute; }
  .sample-pane.split-focused { outline: 2px solid color-mix(in srgb, var(--accent) 55%, transparent); outline-offset: -2px; }
  .agent-frame { position: absolute; inset: 0; z-index: 8; box-sizing: border-box; border: 2px solid #d97757; border-radius: inherit; pointer-events: none; }
  .agent-frame > span { position: absolute; right: 9px; top: 9px; border-radius: 10px; padding: 2px 8px; background: #d97757; color: white; font: 600 11px/16px -apple-system, BlinkMacSystemFont, sans-serif; }
  .agent-cursor { position: absolute; z-index: 9; pointer-events: none; transform: translate(-3px, -2px); transition: left .15s ease-out, top .15s ease-out; }
  .agent-cursor svg { display: block; width: 22px; height: 26px; overflow: visible; fill: #d97757; stroke: white; stroke-width: 1.6; stroke-linejoin: round; filter: drop-shadow(0 1px 2px #00000055); }
  .agent-cursor > span { position: absolute; left: 15px; top: 20px; border: 1px solid #ffffffd9; border-radius: 9px; padding: 0 7px; background: #d97757; color: white; font: 600 11px/17px -apple-system, BlinkMacSystemFont, sans-serif; }
  .agent-cursor.pressed::before { content: ""; position: absolute; top: -12px; left: -11px; width: 28px; height: 28px; border: 2px solid #d97757; border-radius: 50%; background: #d9775733; animation: agent-click .4s ease-out forwards; }
  @keyframes agent-click { from { opacity: 1; transform: scale(.6); } to { opacity: 0; transform: scale(1.2); } }
  @media (prefers-reduced-motion: reduce) { .agent-cursor { transition: none; } .agent-cursor.pressed::before { display: none; } }
  :global(.reduced-power) .agent-cursor { transition: none; }
  .close-split { position: absolute; top: 8px; right: 9px; z-index: 5; width: 22px; height: 22px; border: 1px solid var(--border); border-radius: 50%; background: var(--bg-primary); color: var(--text-secondary); cursor: pointer; }
  .native-menu { position: fixed; z-index: 60000; width: max-content; min-width: 220px; max-width: min(360px, calc(100vw - 16px)); max-height: calc(100vh - 16px); overflow: auto; border: 1px solid var(--border); padding: 5px; border-radius: 8px; background: var(--bg-elevated); box-shadow: 0 10px 35px #00000030, 0 0 0 0.5px #00000012; color: var(--text-primary); font: 13px/1.4 -apple-system, BlinkMacSystemFont, sans-serif; }
  .context-submenu { z-index: 60001; }
  .native-menu button { display: flex; align-items: center; gap: 5px; width: 100%; min-height: 27px; border: 0; border-radius: 4px; padding: 4px 8px 4px 3px; background: none; color: inherit; font: inherit; text-align: left; cursor: pointer; }
  .native-menu button:not(:disabled):hover, .native-menu button:focus-visible, .native-menu button[aria-expanded="true"] { outline: none; background: #416bcd; color: white; }
  .native-menu button:disabled { color: var(--text-tertiary); cursor: default; }
  .menu-check { flex: none; width: 14px; text-align: center; }
  .menu-label { min-width: 0; flex: 1; }
  .menu-chevron { padding-left: 12px; font-size: 20px; line-height: 16px; }
  .menu-mac { margin-left: 12px; font-size: 10px; }
  .native-menu hr { border: 0; border-top: 1px solid var(--border); margin: 4px 7px; }
  .demo-confirmation { position: fixed; inset: 0; z-index: 60002; pointer-events: none; }
  .notice { position: fixed; bottom: 18px; left: calc(50% + 90px); transform: translateX(-50%); z-index: 100000; display: flex; align-items: center; gap: 15px; max-width: 430px; padding: 12px 15px; border: 1px solid var(--border); border-radius: 12px; background: var(--bg-elevated); color: var(--text-primary); font: 12px/1.5 -apple-system, sans-serif; box-shadow: 0 5px 20px #00000020; }
  .notice button { border: 0; padding: 0 3px; background: none; color: var(--text-secondary); font: 18px/1 -apple-system, sans-serif; cursor: pointer; }
  .restore-window { position: fixed; inset: 0; display: grid; place-content: center; justify-items: center; gap: 20px; color: var(--text-primary); font: 14px/1.5 -apple-system, sans-serif; }
  .restore-window p { margin: 0; } .restore-window button { background: var(--bg-primary); color: var(--text-primary); padding: 8px 22px; border: 1px solid var(--border); border-radius: 9px; font: inherit; cursor: pointer; }
</style>
