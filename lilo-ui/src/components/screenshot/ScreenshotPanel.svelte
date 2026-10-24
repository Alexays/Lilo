<script lang="ts">
  import { onDestroy } from "svelte";
  import { flip } from "svelte/animate";
  import { springEase } from "../../lib/motion/spring";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import PanelHeader from "../ui/PanelHeader.svelte";
  import InkStylePanel from "./InkStylePanel.svelte";
  import ToolIcon from "./ToolIcon.svelte";
  import { SHARED_TOOL_KEYS } from "../../lib/ink";
  import { tooltip } from "../../lib/tooltip";
  import { dndItem, dndZone } from "../../lib/dndEngine/action";
  import type { DndActiveDrag } from "../../lib/dndEngine/store.svelte";
  import type { DndItem } from "../../lib/dndEngine/types";
  import { LINE_TYPES, screenshotEditor } from "../../stores/screenshotEditor.svelte";
  import type { ToolKind, Annotation } from "../../lib/screenshot/annotationModel";
  import { t } from "../../lib/i18n/state.svelte";

  const LAYER_ZONE = "screenshot-layers";

  // The shared drawing tools carry the ink names; the pen is the editor's "draw" annotation.
  const TOOL_LABEL_KEYS: Record<string, string> = {
    arrow: "ink.tools.arrow", rect: "ink.tools.rect", ellipse: "ink.tools.ellipse",
    text: "ink.tools.text", highlight: "screenshot.toolHighlight", draw: "ink.tools.pen",
    blur: "screenshot.toolBlur", badge: "screenshot.toolBadge", crop: "screenshot.toolCrop",
    select: "ink.tools.select",
  };
  function layerLabel(a: Annotation): string {
    if (a.type === "text") return a.text?.trim() || t("ink.tools.text");
    if (a.type === "badge") return t("screenshot.layerBadge", { number: a.text ?? "" });
    const key = TOOL_LABEL_KEYS[a.type];
    return key ? t(key) : a.type;
  }
  // Top of the list = top of the z-stack (last in the annotations array).
  const layers = $derived([...screenshotEditor.annotations].reverse());

  const TOOLS: { kind: ToolKind; shortcut: string }[] = [
    { kind: "select", shortcut: SHARED_TOOL_KEYS.select },
    { kind: "arrow", shortcut: SHARED_TOOL_KEYS.arrow },
    { kind: "rect", shortcut: SHARED_TOOL_KEYS.rect },
    { kind: "ellipse", shortcut: SHARED_TOOL_KEYS.ellipse },
    { kind: "draw", shortcut: SHARED_TOOL_KEYS.pen },
    { kind: "text", shortcut: SHARED_TOOL_KEYS.text },
    { kind: "highlight", shortcut: "H" },
    { kind: "blur", shortcut: "B" },
    { kind: "badge", shortcut: "N" },
    { kind: "crop", shortcut: "C" },
  ];
  const tools = $derived(TOOLS.map((tool) => {
    const label = t(TOOL_LABEL_KEYS[tool.kind] ?? tool.kind);
    return { kind: tool.kind, label, tip: `${label} (${tool.shortcut})` };
  }));

  // The style rows follow the selected annotation, or else the tool about to draw.
  const selected = $derived(screenshotEditor.annotations.find((a) => a.id === screenshotEditor.selectedId));
  const styledKind = $derived(selected?.type ?? screenshotEditor.tool);
  const panelValue = $derived(selected
    ? { color: selected.color, width: selected.strokeWidth, fill: selected.fill ?? "none", dash: selected.dash ?? "solid", heads: selected.heads ?? "end" }
    : screenshotEditor.style);

  let saveMenuOpen = $state(false);
  let saveGroupEl = $state<HTMLElement>();

  // Live projection (same engine as tabs/spaces): during the drag the layers render in the
  // projected order so the list reorders and flips live, and the drop commits it. The *real* row
  // moves (it never unmounts) so its dndItem action stays alive through the drop.
  let visualLayers = $state<DndItem[] | null>(null);
  let draggingLayerId = $state<string | null>(null);
  const layerBaseItems = $derived(layers.map((l): DndItem => ({ id: l.id, kind: "layer" })));
  const annById = $derived(new Map(screenshotEditor.annotations.map((a) => [a.id, a])));
  // Projected order paired with its annotation (filtered so the each renders a single keyed child).
  const layerZoneItems = $derived(
    (visualLayers ?? layerBaseItems)
      .map((item) => ({ item, ann: annById.get(item.id) }))
      .filter((x): x is { item: DndItem; ann: Annotation } => !!x.ann),
  );

  function projectLayerOrder(draggedId: string, targetIndex: number): DndItem[] {
    const ids = layerBaseItems.map((i) => i.id).filter((id) => id !== draggedId);
    const at = Math.max(0, Math.min(targetIndex, ids.length));
    ids.splice(at, 0, draggedId);
    return ids.map((id): DndItem => ({ id, kind: "layer" }));
  }

  function handleLayerDragStart(drag: DndActiveDrag): void {
    draggingLayerId = drag.source.item.id;
  }

  function handleLayerDragMove(drag: DndActiveDrag): void {
    if (drag.target?.zoneId !== LAYER_ZONE) { visualLayers = null; return; }
    visualLayers = projectLayerOrder(drag.source.item.id, drag.target.index);
  }

  function handleLayerDrop(drag: DndActiveDrag): void {
    const projected = visualLayers ?? projectLayerOrder(drag.source.item.id, drag.target?.index ?? 0);
    visualLayers = null;
    draggingLayerId = null;
    if (drag.target?.zoneId !== LAYER_ZONE) return;
    screenshotEditor.reorderAnnotations([...projected.map((i) => i.id)].reverse()); // store wants bottom-to-top
  }

  function handleLayerCancel(): void {
    visualLayers = null;
    draggingLayerId = null;
  }

  function onWindowPointerDown(e: PointerEvent): void {
    if (saveMenuOpen && saveGroupEl && !saveGroupEl.contains(e.target as Node)) {
      saveMenuOpen = false;
    }
  }

  // Capture phase: the editor's own Escape (cancel the whole capture) must not see this one.
  function onWindowKeydown(e: KeyboardEvent): void {
    if (!saveMenuOpen || e.key !== "Escape") return;
    e.stopPropagation();
    saveMenuOpen = false;
  }

  // Leaving the panel (e.g. another panel opens) tears down the screenshot session
  // so the content overlay never orphans. close() is a no-op if already closed.
  onDestroy(() => {
    if (screenshotEditor.open) screenshotEditor.close();
  });
</script>

<svelte:window onpointerdown={onWindowPointerDown} onkeydowncapture={onWindowKeydown} />

<div class="panel-shell screenshot-panel">
  <PanelHeader title={t("screenshot.title")} onclose={() => screenshotEditor.cancel()}>
    {#snippet actions()}
      <button class="hdr-ctl" disabled={!screenshotEditor.canUndo} onclick={() => screenshotEditor.undo()} use:tooltip={{ text: `${t("screenshot.undo")} (⌘Z)`, placement: "bottom" }} aria-label={t("screenshot.undo")}>
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6 4 3 7l3 3" /><path d="M3 7h6.5a3.5 3.5 0 0 1 0 7H6" /></svg>
      </button>
      <button class="hdr-ctl" disabled={!screenshotEditor.canRedo} onclick={() => screenshotEditor.redo()} use:tooltip={{ text: `${t("screenshot.redo")} (⌘⇧Z)`, placement: "bottom" }} aria-label={t("screenshot.redo")}>
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 4l3 3-3 3" /><path d="M13 7H6.5a3.5 3.5 0 0 0 0 7H10" /></svg>
      </button>
    {/snippet}
  </PanelHeader>

  <div class="screenshot-panel-body">
    <div class="card">
      <p class="group-label">{t("screenshot.tools")}</p>
      <div class="tool-grid" role="toolbar" aria-label={t("screenshot.tools")}>
        {#each tools as tool (tool.kind)}
          <button
            class="tool"
            class:active={screenshotEditor.tool === tool.kind}
            use:tooltip={tool.tip}
            aria-label={tool.label}
            aria-pressed={screenshotEditor.tool === tool.kind}
            onclick={() => screenshotEditor.setTool(tool.kind)}
          ><ToolIcon kind={tool.kind} /></button>
        {/each}
      </div>
    </div>

    <div class="card ink-card">
      <InkStylePanel
        value={panelValue}
        widths={[3, 6, 12]}
        rows={{
          fill: styledKind === "rect" || styledKind === "ellipse",
          heads: styledKind === "arrow",
          dash: (LINE_TYPES as Set<string>).has(styledKind),
        }}
        onChange={(patch) => screenshotEditor.setStyle(patch)}
      />
    </div>

    <div class="card">
      <p class="group-label">{t("screenshot.layers")}</p>
      {#if layers.length === 0}
        <p class="layers-empty">{t("screenshot.noAnnotations")}</p>
      {:else}
        <div class="layer-list" use:dndZone={{ id: LAYER_ZONE, axis: "vertical", getItems: () => layerZoneItems.map((x) => x.item), canResolve: (ctx) => ctx.dragSource.kind === "layer" }}>
          {#each layerZoneItems as { item, ann } (item.id)}
            <div
              class="layer"
              class:active={screenshotEditor.selectedId === ann.id}
              class:placeholder={draggingLayerId === ann.id}
              animate:flip={{ duration: prefersReducedMotion() ? 0 : 260, easing: springEase }}
              role="button"
              tabindex="0"
              use:dndItem={{
                item,
                zoneId: LAYER_ZONE,
                onDragStart: handleLayerDragStart,
                onDragMove: handleLayerDragMove,
                onDrop: handleLayerDrop,
                onCancel: handleLayerCancel,
              }}
              onclick={() => screenshotEditor.select(ann.id)}
              onkeydown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); screenshotEditor.select(ann.id); } }}
            >
              <span class="layer-grip" aria-hidden="true">
                <svg width="10" height="14" viewBox="0 0 10 14" fill="currentColor"><circle cx="3" cy="3" r="1.1" /><circle cx="7" cy="3" r="1.1" /><circle cx="3" cy="7" r="1.1" /><circle cx="7" cy="7" r="1.1" /><circle cx="3" cy="11" r="1.1" /><circle cx="7" cy="11" r="1.1" /></svg>
              </span>
              <span class="layer-icon"><ToolIcon kind={ann.type} /></span>
              <span class="layer-label">{layerLabel(ann)}</span>
              <span class="layer-color" style={`background:${ann.color}`}></span>
              <button class="layer-btn delete" aria-label={t("screenshot.deleteLayer")} onclick={(e) => { e.stopPropagation(); screenshotEditor.deleteAnnotation(ann.id); }}>
                <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4.5h10M6.5 4.5V3h3v1.5M5 4.5l.6 9h4.8l.6-9" /></svg>
              </button>
            </div>
          {/each}
        </div>
      {/if}
    </div>
  </div>

  <div class="screenshot-panel-actions">
    <div class="save-group" bind:this={saveGroupEl}>
      <button class="btn primary" disabled={!screenshotEditor.captured} use:tooltip={`${t("common.save")} (⌘S)`} onclick={() => screenshotEditor.save()}>
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3h7l3 3v7a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1Z" /><path d="M5 3v3h5" /><path d="M5 13v-3h6v3" /></svg>
        <span>{t("common.save")}</span>
      </button>
      <button class="btn primary chevron" disabled={!screenshotEditor.captured} aria-label={t("screenshot.saveOptions")} aria-haspopup="menu" aria-expanded={saveMenuOpen} use:tooltip={t("screenshot.saveOptions")} onclick={() => (saveMenuOpen = !saveMenuOpen)}>
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6l4 4 4-4" /></svg>
      </button>
      {#if saveMenuOpen}
        <div class="save-menu" role="menu" aria-label={t("screenshot.saveOptions")}>
          <button role="menuitem" onclick={() => { saveMenuOpen = false; screenshotEditor.saveAs(); }}>{t("screenshot.saveAs")}</button>
        </div>
      {/if}
    </div>
    <div class="secondary-row">
      <button class="btn with-icon" disabled={!screenshotEditor.captured} use:tooltip={`${t("screenshot.copyToClipboard")} (⌘C)`} onclick={() => screenshotEditor.copy()}>
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="5" width="8" height="9" rx="1.5" /><path d="M3 11V3a1 1 0 0 1 1-1h6" /></svg>
        <span>{t("common.copy")}</span>
      </button>
      <button class="btn ghost" use:tooltip={t("screenshot.cancelShortcut")} onclick={() => screenshotEditor.cancel()}>{t("common.cancel")}</button>
    </div>
  </div>
</div>

<style>
  .screenshot-panel-body { padding: 4px 12px 8px; display: flex; flex-direction: column; gap: 10px; overflow-y: auto; }

  /* The curved undo/redo glyphs are drawn ~1px below the viewBox centre: nudge for optical balance. */
  .hdr-ctl svg { transform: translateY(-1px); }
  .hdr-ctl:disabled { opacity: var(--disabled-opacity); }

  .card { background: var(--bg-elevated); border: 1px solid var(--border); border-radius: var(--radius-lg); padding: 10px 12px; display: flex; flex-direction: column; gap: 8px; }
  .group-label { margin: 0; font-size: var(--font-size-2xs); letter-spacing: 0.4px; text-transform: uppercase; color: var(--text-primary); }

  .ink-card { color: var(--text-primary); }
  .tool-grid { display: flex; flex-wrap: wrap; gap: 4px; }
  .tool { width: 34px; height: 34px; border-radius: var(--radius-md); border: none; display: grid; place-items: center; color: var(--text-primary); background: var(--bg-secondary); cursor: pointer; }
  .tool:hover { background: var(--bg-tertiary); }
  .tool.active { background: var(--accent); color: var(--accent-text); }


  .layers-empty { font-size: var(--font-size-xs); color: var(--text-muted); margin: 0; }
  .layer-list { display: flex; flex-direction: column; gap: 4px; max-height: 168px; overflow-y: auto; }
  .layer { display: flex; align-items: center; gap: 8px; padding: 4px 4px 4px 2px; border-radius: var(--radius-sm); cursor: pointer; color: var(--text-primary); }
  .layer:hover { background: var(--bg-secondary); }
  .layer.active { background: var(--accent-tint-22); }
  .layer:focus-visible { outline: var(--focus-outline); outline-offset: -2px; }
  /* While dragging, the row becomes a dashed placeholder gap (content hidden): the cue is the
     placeholder moving to its drop position, not a floating clone. */
  .layer.placeholder { border: 1.5px dashed var(--accent); background: var(--accent-tint-12); }
  .layer.placeholder > * { visibility: hidden; }
  .layer-grip { display: flex; color: var(--text-muted); cursor: grab; flex: none; }
  .layer-grip:active { cursor: grabbing; }
  .layer-icon { display: flex; color: var(--text-secondary); }
  .layer-label { flex: 1; font-size: var(--font-size-xs); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .layer-color { width: 12px; height: 12px; border-radius: var(--radius-xs); border: 1px solid var(--border); flex: none; }
  .layer-btn { width: 20px; height: 20px; border: none; background: transparent; color: var(--text-muted); cursor: pointer; border-radius: var(--radius-xs); display: grid; place-items: center; flex: none; }
  .layer-btn:hover:not(:disabled) { background: var(--bg-tertiary); color: var(--text-primary); }
  .layer-btn.delete:hover { background: color-mix(in srgb, var(--danger) 18%, transparent); color: var(--danger-text); }
  .layer-btn:disabled { opacity: var(--disabled-opacity); cursor: default; }


  .screenshot-panel-actions { margin-top: auto; padding: 12px; display: flex; flex-direction: column; gap: 8px; border-top: 1px solid var(--border); }
  .secondary-row { display: flex; gap: 8px; }
  .secondary-row .btn { flex: 1; }
  .btn { display: inline-flex; align-items: center; justify-content: center; gap: 6px; font-size: var(--font-size-sm); font-weight: var(--font-weight-semibold); padding: 10px; border-radius: var(--radius-md); border: none; background: var(--bg-secondary); color: var(--text-primary); cursor: pointer; text-align: center; }
  .btn svg { flex: none; }
  .btn:hover { background: var(--bg-tertiary); }
  .btn.primary { background: var(--accent); color: var(--accent-text); }
  .btn.primary:hover { filter: brightness(1.05); background: var(--accent); }
  .btn.ghost { background: transparent; color: var(--text-muted); }
  .btn.ghost:hover { background: var(--bg-hover); }
  .btn:disabled { opacity: var(--disabled-opacity); cursor: default; pointer-events: none; }

  .save-group { position: relative; display: flex; gap: 1px; }
  .save-group .primary:first-child { flex: 1; border-radius: var(--radius-md) 0 0 var(--radius-md); }
  .save-group .chevron { border-radius: 0 var(--radius-md) var(--radius-md) 0; padding: 0 12px; display: flex; align-items: center; justify-content: center; }
  .save-menu { position: absolute; bottom: calc(100% + 6px); left: 0; right: 0; background: var(--bg-elevated); border: 1px solid var(--border); border-radius: var(--radius-md); padding: 4px; box-shadow: var(--shadow-md); }
  .save-menu button { width: 100%; white-space: nowrap; border: none; background: transparent; color: var(--text-primary); padding: 8px 10px; border-radius: var(--radius-sm); cursor: pointer; font-size: var(--font-size-sm); text-align: left; }
  .save-menu button:hover { background: var(--bg-hover); }
</style>
