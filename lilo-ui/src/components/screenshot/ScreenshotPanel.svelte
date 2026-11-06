<script lang="ts">
  import { onDestroy } from "svelte";
  import { flip } from "svelte/animate";
  import { springEase } from "../../lib/motion/spring";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import PanelHeader from "../ui/PanelHeader.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiSplitButton from "../ui/UiSplitButton.svelte";
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
    if (drag.target?.zoneId !== LAYER_ZONE || drag.target.index === undefined) { visualLayers = null; return; }
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

  // Leaving the panel (e.g. another panel opens) tears down the screenshot session
  // so the content overlay never orphans. close() is a no-op if already closed.
  onDestroy(() => {
    if (screenshotEditor.open) screenshotEditor.close();
  });
</script>

<div class="panel-shell screenshot-panel">
  <PanelHeader title={t("screenshot.title")} onclose={() => screenshotEditor.cancel()}>
    {#snippet actions()}
      <button class="hdr-ctl" disabled={!screenshotEditor.canUndo} onclick={() => screenshotEditor.undo()} use:tooltip={{ text: `${t("screenshot.undo")} (⌘Z)`, placement: "bottom" }} aria-label={t("screenshot.undo")}>
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6 4 3 7l3 3" /><path d="M3 7h6.5a3.5 3.5 0 0 1 0 7H6" /></svg>
      </button>
      <button class="hdr-ctl" disabled={!screenshotEditor.canRedo} onclick={() => screenshotEditor.redo()} use:tooltip={{ text: `${t("screenshot.redo")} (⇧⌘Z)`, placement: "bottom" }} aria-label={t("screenshot.redo")}>
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 4l3 3-3 3" /><path d="M13 7H6.5a3.5 3.5 0 0 0 0 7H10" /></svg>
      </button>
    {/snippet}
  </PanelHeader>

  <div class="screenshot-panel-body">
    <UiInsetList title={t("screenshot.tools")} boxed={false}>
      <div class="card tool-grid" role="toolbar" aria-label={t("screenshot.tools")}>
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
    </UiInsetList>

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

    <UiInsetList title={t("screenshot.layers")} boxed={false}>
      {#if layers.length === 0}
        <p class="card layers-empty">{t("screenshot.noAnnotations")}</p>
      {:else}
        <div class="card layer-list" use:dndZone={{ id: LAYER_ZONE, axis: "vertical", getItems: () => layerZoneItems.map((x) => x.item), canResolve: (ctx) => ctx.dragSource.kind === "layer" }}>
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
    </UiInsetList>
  </div>

  <div class="screenshot-panel-actions">
    <div class="action" use:tooltip={`${t("common.save")} (⌘S)`}>
      <UiSplitButton
        menuLabel={t("screenshot.saveOptions")}
        variants={[{ label: t("screenshot.saveAs"), onclick: () => screenshotEditor.saveAs() }]}
        disabled={!screenshotEditor.captured}
        onclick={() => screenshotEditor.save()}
      >{t("common.save")}</UiSplitButton>
    </div>
    <div class="secondary-row">
      <div class="action" use:tooltip={`${t("screenshot.copyToClipboard")} (⌘C)`}>
        <UiButton disabled={!screenshotEditor.captured} onclick={() => screenshotEditor.copy()}>{t("common.copy")}</UiButton>
      </div>
      <div class="action" use:tooltip={t("screenshot.cancelShortcut")}>
        <UiButton variant="ghost" onclick={() => screenshotEditor.cancel()}>{t("common.cancel")}</UiButton>
      </div>
    </div>
  </div>
</div>

<style>
  .screenshot-panel-body { padding: 4px 12px 8px; display: flex; flex-direction: column; gap: 10px; overflow-y: auto; }

  /* The curved undo/redo glyphs are drawn ~1px below the viewBox centre: nudge for optical balance. */
  .hdr-ctl svg { transform: translateY(-1px); }
  .hdr-ctl:disabled { opacity: var(--disabled-opacity); }

  .card { margin: 0; background: var(--bg-elevated); border: 1px solid var(--border); border-radius: var(--radius-md); padding: 10px 12px; }

  .ink-card { color: var(--text-primary); }
  .tool-grid { display: flex; flex-wrap: wrap; gap: 4px; }
  .tool { width: 34px; height: 34px; border-radius: var(--radius-md); border: none; display: grid; place-items: center; color: var(--text-primary); background: var(--bg-secondary); cursor: pointer; }
  .tool:hover { background: var(--bg-tertiary); }
  .tool.active { background: var(--accent); color: var(--accent-text); }
  .tool:focus-visible { outline: var(--focus-outline); outline-offset: 1px; }


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
  .action { display: flex; flex: 1; min-width: 0; }
  /* The panel takes the Space's tint, where the muted title falls under the text contrast bar. */
  .screenshot-panel-body :global(.ui-inset-list-title) { color: var(--text-primary); }
  .action :global(.ui-button) { flex: 1; }
  .action :global(.ui-split-button) { flex: 1; height: var(--control-height-md); border-radius: var(--radius-md); }
  .action :global(.ui-split-button .main) { flex: 1; justify-content: center; font-size: var(--font-size-md); border-radius: var(--radius-md) 0 0 var(--radius-md); }
  .action :global(.ui-split-button .chevron) { width: 28px; border-radius: 0 var(--radius-md) var(--radius-md) 0; }
</style>
