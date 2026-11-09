<script lang="ts" module>
  import type { BridgeConversationAttachment } from "../../lib/bridge/protocol";

  /** An attachment with what its chip shows. */
  export interface AttachmentDraft {
    key: string;
    label: string;
    attachment: BridgeConversationAttachment;
  }
</script>

<script lang="ts">
  import { scale } from "svelte/transition";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { untrack } from "svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { hostOf } from "../../lib/url";
  import { getFolders } from "../../stores/folders.svelte";
  import { getProjectFiles, searchProjectFiles } from "./projectFiles.svelte";
  import { getActiveSpaceId } from "../../stores/spaces.svelte";
  import { getOpenTabs, getTabsById, tabDisplayTitle } from "../../stores/tabs.svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import UiChip from "../ui/UiChip.svelte";
  import Icon from "../ui/Icon.svelte";
  import type { IconName } from "../ui/icons";
  import type { AvailableCommand } from "./conversationModel";

  const CHIP_ICONS: Record<BridgeConversationAttachment["kind"], IconName> = {
    tab: "globe",
    selection: "queue",
    screenshot: "image",
    image: "image",
    folder: "folder",
    file: "file",
  };

  interface Props {
    text: string;
    attachments: AttachmentDraft[];
    placeholder: string;
    /** The web page "Selection" and "Screenshot" come from, if any. */
    pageTabId?: string | null;
    /** The project whose files @ offers. */
    cwd?: string;
    commands?: AvailableCommand[];
    /** A `/` typed while the agent has listed no commands yet. */
    oncommandsneeded?: () => void;
    /** `alternate` is Cmd+Return. */
    onsubmit: (alternate: boolean) => void;
    /** Escape with no menu open; return true when it was used. */
    onescape?: () => boolean;
    /** Return on an empty field, `alt` when Option is held; return true when it was used. */
    onemptyreturn?: (alt: boolean) => boolean;
    /** Up arrow on an empty field; return true when it was used. */
    onemptyup?: () => boolean;
    /** A character typed into an empty field, before it lands; return true when it was used. */
    onemptykey?: (key: string) => boolean;
    ariaLabel: string;
  }

  let {
    text = $bindable(),
    attachments = $bindable(),
    placeholder,
    pageTabId = null,
    cwd = "",
    commands = [],
    oncommandsneeded,
    onsubmit,
    onescape,
    onemptyreturn,
    onemptyup,
    onemptykey,
    ariaLabel,
  }: Props = $props();

  type PickerItem = {
    key: string;
    group: string;
    label: string;
    detail?: string;
    kind?: BridgeConversationAttachment["kind"];
    tab?: { favicon?: string; title: string; url: string };
    pick: () => void;
  };

  /** The most rows tabs, and folders, each get: neither group buries the project's files. */
  const MAX_TABS = 8;
  const MAX_HEIGHT = 200;
  const listId = $props.id();
  let textareaEl: HTMLTextAreaElement | undefined = $state();
  let trigger = $state.raw<{ char: "@" | "/"; query: string; start: number } | null>(null);
  let highlighted = $state(0);

  export function focus(): void {
    textareaEl?.focus();
  }

  /** Types "@" at the caret and opens its menu, for the composer's @ button. */
  export function startMention(): void {
    if (!textareaEl) return;
    const caret = textareaEl.selectionStart;
    const before = text.slice(0, caret);
    const insert = before && !/\s$/.test(before) ? " @" : "@";
    text = before + insert + text.slice(textareaEl.selectionEnd);
    textareaEl.focus();
    requestAnimationFrame(() => {
      if (!textareaEl) return;
      textareaEl.setSelectionRange(caret + insert.length, caret + insert.length);
      updateTrigger();
    });
  }

  function updateTrigger(): void {
    if (!textareaEl) return;
    const caret = textareaEl.selectionStart;
    const match = /(^|\s)([@/])([^\s@/]*)$/.exec(text.slice(0, caret));
    const char = match?.[2] as "@" | "/" | undefined;
    const start = match ? match.index + match[1].length : -1;
    if (char === "/" && start === 0 && commands.length === 0) oncommandsneeded?.();
    // Commands only open the prompt.
    const next = match && char && (char === "@" || (start === 0 && commands.length > 0))
      ? { char, query: match[3], start }
      : null;
    if (next?.char !== trigger?.char || next?.query !== trigger?.query || next?.start !== trigger?.start) {
      trigger = next;
      highlighted = 0;
    }
  }

  function resize(): void {
    if (!textareaEl) return;
    textareaEl.style.height = "auto";
    textareaEl.style.height = `${Math.min(textareaEl.scrollHeight, MAX_HEIGHT)}px`;
  }

  $effect(() => {
    void text;
    resize();
  });

  // Commands that arrive while a `/` waits for them open the menu.
  $effect(() => {
    void commands;
    untrack(updateTrigger);
  });

  function replaceTrigger(insert: string): void {
    if (!trigger || !textareaEl) return;
    const end = textareaEl.selectionStart;
    const caret = trigger.start + insert.length;
    text = text.slice(0, trigger.start) + insert + text.slice(end);
    trigger = null;
    requestAnimationFrame(() => textareaEl?.setSelectionRange(caret, caret));
  }

  function attach(draft: AttachmentDraft): void {
    replaceTrigger("");
    if (!attachments.some((existing) => existing.key === draft.key)) attachments = [...attachments, draft];
  }

  $effect(() => {
    if (trigger?.char === "@" && trigger.query && cwd) searchProjectFiles(cwd, trigger.query);
  });

  // A pasted image goes along as an attachment, as long as it is small enough to send in one message.
  function pasteImage(event: ClipboardEvent): void {
    const file = [...(event.clipboardData?.items ?? [])].find((item) => item.type.startsWith("image/"))?.getAsFile();
    if (!file || file.size > 5 * 1024 * 1024) return;
    event.preventDefault();
    const reader = new FileReader();
    reader.onload = () => {
      const data = String(reader.result).split(",")[1] ?? "";
      const key = `image:${data.length}:${data.slice(-16)}`;
      if (!attachments.some((existing) => existing.key === key)) {
        attachments = [...attachments, { key, label: t("agents.composer.image"), attachment: { kind: "image", data, mimeType: file.type } }];
      }
    };
    reader.readAsDataURL(file);
  }

  const items = $derived.by((): PickerItem[] => {
    if (!trigger) return [];
    const query = trigger.query.toLowerCase();
    const matches = (...values: (string | undefined)[]) =>
      !query || values.some((value) => value?.toLowerCase().includes(query));
    if (trigger.char === "/") {
      return commands
        .filter((command) => command.name.toLowerCase().startsWith(query))
        .map((command) => ({
          key: `command:${command.name}`,
          group: t("agents.composer.commands"),
          label: `/${command.name}`,
          // A plugin's command already names its plugin, which its description repeats as "(plugin) ".
          detail: command.description.replace(/^\(([^)]+)\)\s*/, (prefix, plugin) => (command.name.startsWith(`${plugin}:`) ? "" : prefix)),
          pick: () => replaceTrigger(`/${command.name} `),
        }));
    }
    const out: PickerItem[] = [];
    const tabs = getOpenTabs().filter((tab) => tab.kind === "web" && tab.url);
    for (const tab of tabs) {
      if (out.length >= MAX_TABS) break;
      const title = tabDisplayTitle(tab.title);
      const host = hostOf(tab.url) ?? undefined;
      if (!matches(title, host)) continue;
      out.push({
        key: `tab:${tab.id}`,
        group: t("agents.composer.tabs"),
        label: title,
        detail: host,
        kind: "tab",
        tab: { favicon: tab.faviconDataURL, title: tab.title, url: tab.url },
        pick: () => attach({ key: `tab:${tab.id}`, label: title, attachment: { kind: "tab", tabId: tab.id } }),
      });
    }
    const found = getProjectFiles();
    if (cwd && found.cwd === cwd && found.query === trigger.query) {
      for (const file of found.files.slice(0, 8)) {
        const slash = file.lastIndexOf("/");
        const path = `${cwd}/${file}`;
        out.push({
          key: `file:${path}`,
          group: t("agents.composer.files"),
          label: file.slice(slash + 1),
          detail: slash > 0 ? file.slice(0, slash) : undefined,
          kind: "file",
          pick: () => attach({ key: `file:${path}`, label: file.slice(slash + 1), attachment: { kind: "file", path } }),
        });
      }
    }
    let folders = 0;
    for (const folder of getFolders(getActiveSpaceId())) {
      if (folders >= MAX_TABS) break;
      if (!matches(folder.name)) continue;
      folders++;
      out.push({
        key: `folder:${folder.id}`,
        group: t("agents.composer.folders"),
        label: folder.name,
        kind: "folder",
        pick: () => attach({ key: `folder:${folder.id}`, label: folder.name, attachment: { kind: "folder", folderId: folder.id } }),
      });
    }
    const page = pageTabId ? getTabsById().get(pageTabId) : undefined;
    if (page) {
      const pageTitle = tabDisplayTitle(page.title);
      for (const kind of ["selection", "screenshot"] as const) {
        const label = t(`agents.composer.${kind}`);
        if (!matches(label)) continue;
        out.push({
          key: `${kind}:${page.id}`,
          group: t("agents.composer.fromPage"),
          label,
          detail: pageTitle,
          kind,
          pick: () => attach({ key: `${kind}:${page.id}`, label, attachment: { kind, tabId: page.id } }),
        });
      }
    }
    const path = trigger.query;
    if (path && (path.startsWith("/") || path.startsWith("~"))) {
      out.push({
        key: `file:${path}`,
        group: t("agents.composer.more"),
        label: t("agents.composer.file", { path }),
        kind: "file",
        pick: () => attach({ key: `file:${path}`, label: path.split("/").filter(Boolean).pop() ?? path, attachment: { kind: "file", path } }),
      });
    }
    return out;
  });

  const open = $derived(trigger !== null && (items.length > 0 || trigger.char === "@"));

  function handleKeydown(event: KeyboardEvent): void {
    if (event.isComposing) return;
    if (open) {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        if (items.length) highlighted = (highlighted + (event.key === "ArrowDown" ? 1 : items.length - 1)) % items.length;
        return;
      }
      if ((event.key === "Enter" || event.key === "Tab") && items.length && !event.metaKey) {
        event.preventDefault();
        items[highlighted]?.pick();
        return;
      }
      if (event.key === "Escape") {
        event.preventDefault();
        trigger = null;
        return;
      }
    }
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      if (!text.trim() && !event.metaKey && onemptyreturn?.(event.altKey)) return;
      onsubmit(event.metaKey);
      return;
    }
    if (event.key === "Escape" && onescape?.()) {
      event.preventDefault();
      return;
    }
    if (!text && event.key.length === 1 && !event.metaKey && !event.ctrlKey && !event.altKey && onemptykey?.(event.key)) {
      event.preventDefault();
      return;
    }
    if (event.key === "ArrowUp" && !text && !event.shiftKey && onemptyup?.()) {
      event.preventDefault();
      return;
    }
    if (event.key === "Backspace" && attachments.length && textareaEl?.selectionStart === 0 && textareaEl.selectionEnd === 0) {
      attachments = attachments.slice(0, -1);
    }
  }
</script>

<div class="prompt-field">
  {#if open}
    <div
      class="picker float-surface"
      class:wide={trigger?.char === "/"}
      id={listId}
      role="listbox"
      aria-label={ariaLabel}
      use:reportInteractiveZone={{ id: `prompt-picker-${listId}` }}
    >
      {#each items as item, index (item.key)}
        {#if index === 0 || items[index - 1].group !== item.group}
          <div class="picker-group" role="presentation">{item.group}</div>
        {/if}
        <div
          id="{listId}-{index}"
          class="picker-item"
          class:highlighted={index === highlighted}
          role="option"
          aria-selected={index === highlighted}
          tabindex="-1"
          onmousedown={(event) => event.preventDefault()}
          onmouseenter={() => (highlighted = index)}
          onclick={item.pick}
          onkeydown={() => {}}
        >
          {#if item.tab}
            <SiteFavicon src={item.tab.favicon} title={item.tab.title} url={item.tab.url} size={14} radius={3} />
          {:else if item.kind}
            <span class="picker-icon"><Icon name={CHIP_ICONS[item.kind]} size={12} /></span>
          {/if}
          <span class="picker-label">{item.label}</span>
          {#if item.detail}<span class="picker-detail">{item.detail}</span>{/if}
        </div>
      {/each}
      {#if trigger?.char === "@" && !trigger.query}
        <div class="picker-hint">{t("agents.composer.fileHint")}</div>
      {/if}
    </div>
  {/if}
  {#if attachments.length}
    <div class="chips">
      {#each attachments as draft (draft.key)}
        {@const attachment = draft.attachment}
        {@const page = attachment.kind === "tab" ? getTabsById().get(attachment.tabId) : undefined}
        <span class="chip" in:scale={{ start: 0.9, duration: prefersReducedMotion() ? 0 : 180 }}>
          <UiChip
            label={draft.label}
            removeLabel={t("agents.composer.removeAttachment", { label: draft.label })}
            onremove={() => (attachments = attachments.filter((other) => other.key !== draft.key))}
          >
            {#snippet icon()}
              {#if page}
                <SiteFavicon src={page.faviconDataURL} title={page.title} url={page.url} size={14} radius={3} />
              {:else}
                <span class="chip-icon"><Icon name={CHIP_ICONS[attachment.kind]} size={12} /></span>
              {/if}
            {/snippet}
          </UiChip>
        </span>
      {/each}
    </div>
  {/if}
  <textarea
    bind:this={textareaEl}
    bind:value={text}
    rows="1"
    {placeholder}
    aria-label={ariaLabel}
    role="combobox"
    aria-expanded={open}
    aria-controls={listId}
    aria-autocomplete="list"
    aria-activedescendant={open && items.length ? `${listId}-${highlighted}` : undefined}
    spellcheck="true"
    oninput={updateTrigger}
    onpaste={pasteImage}
    onclick={updateTrigger}
    onkeyup={(event) => {
      if (event.key === "ArrowLeft" || event.key === "ArrowRight") updateTrigger();
    }}
    onblur={() => (trigger = null)}
    onkeydown={handleKeydown}
  ></textarea>
</div>

<style>
  .prompt-field {
    position: relative;
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
  }

  .chips {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-6);
  }

  .chip {
    display: inline-flex;
    min-width: 0;
  }

  .chips :global(.ui-chip) {
    gap: var(--space-6);
    background: none;
    box-shadow: inset 0 0 0 1px var(--border);
    color: var(--text-primary);
  }

  .chip-icon {
    display: grid;
    color: var(--text-secondary);
  }

  textarea {
    width: 100%;
    min-height: 22px;
    margin: 0;
    padding: 0;
    border: 0;
    background: none;
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-lg);
    line-height: 1.5;
    resize: none;
    outline: none;
  }

  textarea::placeholder {
    color: var(--text-muted);
  }

  .picker {
    position: absolute;
    left: calc(-1 * var(--space-6));
    bottom: calc(100% + var(--space-12));
    width: min(320px, 100%);
    max-height: 320px;
    overflow-y: auto;
    padding: var(--space-6);
    border-radius: var(--radius-md);
    font-size: var(--font-size-md);
    z-index: 2;
    transform-origin: 0 100%;
    animation: picker-in var(--motion-duration-fast) var(--motion-ease-spring);
  }

  /* Commands are told apart by their descriptions, which need the room. */
  .picker.wide {
    width: min(560px, 100%);
  }

  @keyframes picker-in {
    from {
      opacity: 0;
      transform: translateY(4px) scale(0.98);
    }
  }

  .picker-group {
    padding: var(--space-6) var(--space-8) var(--space-2);
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
  }

  .picker-item {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    height: var(--control-height-md);
    padding: 0 var(--space-8);
    border-radius: calc(var(--radius-md) - var(--space-2));
    cursor: default;
  }

  .picker-item.highlighted {
    background: var(--bg-hover);
  }

  .picker-icon {
    flex: none;
    width: 14px;
    display: grid;
    place-items: center;
    color: var(--text-secondary);
  }

  /* The name is what gets picked: it keeps its width, and the detail shortens first. */
  .picker-label {
    flex: none;
    max-width: 75%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .picker-detail {
    flex: 1;
    min-width: 0;
    margin-left: auto;
    text-align: right;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  .picker-hint {
    padding: var(--space-6) var(--space-8) var(--space-2);
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }
</style>
