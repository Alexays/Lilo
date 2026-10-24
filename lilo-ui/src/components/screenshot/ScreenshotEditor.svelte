<script lang="ts">
  import { LINE_TYPES, screenshotEditor } from "../../stores/screenshotEditor.svelte";
  import { arrowPath, dashArray, SHARED_TOOL_KEYS, snapAngle } from "../../lib/ink";
  import {
    createAnnotation, normalizeBox, hitTest, moveAnnotation, boundsOfPoints, smoothPath,
    type Annotation, type Handle,
  } from "../../lib/screenshot/annotationModel";
  import { BLUR_RADIUS_PX, flattenToPNG } from "../../lib/screenshot/export";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { createFrameScheduler } from "../../lib/motion/frameScheduler";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { isSidebarVisible } from "../../stores/ui.svelte";
  import { cubicOut } from "svelte/easing";
  import { fade } from "svelte/transition";
  import { t } from "../../lib/i18n/state.svelte";
  import ExtensionSpinner from "../extensions/ExtensionSpinner.svelte";

  function liftoff(node: Element, { duration = 300 } = {}) {
    if (prefersReducedMotion()) return { duration: 0 };
    // The scroll layout (tall captures) conflicts with a scale transform: skip the animation.
    if (node.parentElement?.classList.contains("tall")) return { duration: 0 };
    // The capture starts filling the content region (.screenshot-editor, not the padded .stage) so it overlays exactly
    // where the page sat, then settles into the framed size.
    const r = node.getBoundingClientRect();
    const region = node.parentElement?.parentElement?.getBoundingClientRect();
    const start = region && r.width > 0 && r.height > 0
      ? Math.min(region.width / r.width, region.height / r.height) // contain: whole capture, faithful
      : 1.2;
    return {
      duration,
      easing: cubicOut,
      css: (t: number) => `transform: scale(${start + (1 - start) * t}); border-radius: ${t * 6}px;`,
    };
  }

  let baseImage: HTMLImageElement | undefined = $state();
  let svgEl: SVGSVGElement | undefined = $state();
  let canvasEl: HTMLDivElement | undefined = $state();

  // Natural image dimensions, captured reactively on load. Reading `baseImage.naturalWidth`
  // directly in the template is NOT reactive to the load event, which would leave the viewBox
  // at "0 0 0 0" and every annotation outside the coordinate space.
  let natW = $state(0);
  let natH = $state(0);
  // Displayed width of the capture, so the blur preview is as strong as the exported blur.
  let canvasW = $state(0);

  function onImageLoad(e: Event): void {
    const img = e.currentTarget as HTMLImageElement;
    natW = img.naturalWidth;
    natH = img.naturalHeight;
  }

  // Local, transient drag state (not shared).
  let drafting = $state.raw<Annotation | null>(null);
  // The pen stroke being drawn, appended in place with its bounds kept up to date: copying it or
  // re-measuring it on every frame would make a long stroke quadratic.
  let strokePoints: { x: number; y: number }[] = [];
  const strokeBounds = { minX: 0, minY: 0, maxX: 0, maxY: 0 };
  let dragOrigin: { x: number; y: number } | null = null;
  let movingId: string | null = null;
  let cropping = $state(false);
  // Displayed-pixels-per-image-pixel, captured when a text edit begins (for input font sizing).
  let editScale = $state(1);

  let activeHandle: Handle | null = null;
  let activeCropHandle: Handle | null = null;

  const HANDLES: { h: Handle; fx: number; fy: number }[] = [
    { h: "nw", fx: 0, fy: 0 }, { h: "n", fx: 0.5, fy: 0 }, { h: "ne", fx: 1, fy: 0 },
    { h: "e", fx: 1, fy: 0.5 }, { h: "se", fx: 1, fy: 1 }, { h: "s", fx: 0.5, fy: 1 },
    { h: "sw", fx: 0, fy: 1 }, { h: "w", fx: 0, fy: 0.5 },
  ];

  const selectedAnnotation = $derived(
    screenshotEditor.selectedId
      ? screenshotEditor.annotations.find((a) => a.id === screenshotEditor.selectedId) ?? null
      : null,
  );

  function onHandleDown(e: PointerEvent, h: Handle): void {
    e.stopPropagation();
    activeHandle = h;
    dragOrigin = toImagePoint(e.clientX, e.clientY);
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }

  function onCropHandleDown(e: PointerEvent, h: Handle): void {
    e.stopPropagation();
    activeCropHandle = h;
    dragOrigin = toImagePoint(e.clientX, e.clientY);
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }

  const editingAnnotation = $derived(
    screenshotEditor.editingTextId
      ? screenshotEditor.annotations.find((a) => a.id === screenshotEditor.editingTextId) ?? null
      : null,
  );

  function captureEditScale(): void {
    if (canvasEl && natW) editScale = canvasEl.getBoundingClientRect().width / natW;
  }

  function focusOnMount(node: HTMLInputElement) {
    // Focus on the next frame: focusing synchronously lets the placing gesture's pointerup/click
    // steal focus straight back, so the input blurs, commits empty, and the text never lands.
    requestAnimationFrame(() => { node.focus(); node.select(); });
  }

  function onTextKeydown(e: KeyboardEvent): void {
    if ((e.key === "Enter" && !e.shiftKey) || e.key === "Escape") {
      e.preventDefault();
      (e.currentTarget as HTMLInputElement).blur(); // onblur commits
    }
    e.stopPropagation();
  }

  function onDblClick(e: MouseEvent): void {
    const p = toImagePoint(e.clientX, e.clientY);
    const hit = hitTest(screenshotEditor.annotations, p);
    if (hit?.type === "text") {
      captureEditScale();
      screenshotEditor.startEditingText(hit.id);
    }
  }
  // Pointer-move coalescing: collapse bursts to one update per animation frame (smooth on 120Hz).
  let pendingMove: { clientX: number; clientY: number; shiftKey: boolean } | null = null;
  const moveFrame = createFrameScheduler();

  const captured = $derived(screenshotEditor.captured);
  // A capture much taller than wide is shown fit-width and scrolled, not shrunk whole.
  const tall = $derived(natW > 0 && natH / natW > 1.4);
  const blurRegions = $derived(screenshotEditor.annotations.filter((a) => a.type === "blur"));
  const vectorAnnotations = $derived(screenshotEditor.annotations.filter((a) => a.type !== "blur"));

  // Register the flattener once mounted; the closure reads live refs + store state at call time.
  $effect(() => {
    screenshotEditor.registerFlattener(async () => {
      if (!baseImage || !svgEl) return null;
      return flattenToPNG(
        baseImage,
        svgEl,
        screenshotEditor.annotations.filter((a) => a.type === "blur"),
        screenshotEditor.crop,
      );
    });
  });

  // Convert client coords to image-pixel coordinates using the canvas box (== displayed image box).
  function toImagePoint(clientX: number, clientY: number): { x: number; y: number } {
    if (!canvasEl || !natW || !natH) return { x: 0, y: 0 };
    const rect = canvasEl.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return { x: 0, y: 0 };
    return {
      x: ((clientX - rect.left) / rect.width) * natW,
      y: ((clientY - rect.top) / rect.height) * natH,
    };
  }

  function onPointerDown(e: PointerEvent): void {
    const p = toImagePoint(e.clientX, e.clientY);
    canvasEl?.setPointerCapture(e.pointerId);
    dragOrigin = p;
    const tool = screenshotEditor.tool;

    if (tool === "select") {
      const hit = hitTest(screenshotEditor.annotations, p);
      screenshotEditor.select(hit?.id ?? null);
      movingId = hit?.id ?? null;
      return;
    }
    if (tool === "crop") {
      cropping = true;
      screenshotEditor.setCrop({ x: p.x, y: p.y, w: 0, h: 0 });
      return;
    }
    if (tool === "badge") {
      screenshotEditor.placeBadge(p.x, p.y);
      dragOrigin = null;
      return;
    }
    if (tool === "text") {
      dragOrigin = null;
      captureEditScale();
      // Clicking an existing text edits it; clicking empty space places a new one.
      const hit = hitTest(screenshotEditor.annotations, p);
      if (hit && hit.type === "text") {
        screenshotEditor.startEditingText(hit.id);
        return;
      }
      screenshotEditor.addTextAnnotation(
        createAnnotation("text", { x: p.x, y: p.y, w: 0, h: 0 }, screenshotEditor.color, screenshotEditor.strokeWidth, ""),
      );
      return;
    }
    const type = tool as Annotation["type"];
    const style = screenshotEditor.style;
    const draft = {
      ...createAnnotation(type, { x: p.x, y: p.y, w: 0, h: 0 }, style.color, style.width),
      ...(type === "rect" || type === "ellipse" ? { fill: style.fill } : {}),
      ...(LINE_TYPES.has(type) ? { dash: style.dash } : {}),
      ...(type === "arrow" ? { heads: style.heads } : {}),
    };
    if (tool === "draw") {
      strokePoints = [p];
      strokeBounds.minX = strokeBounds.maxX = p.x;
      strokeBounds.minY = strokeBounds.maxY = p.y;
      drafting = { ...draft, points: strokePoints };
    } else {
      drafting = draft;
    }
  }

  function onPointerMove(e: PointerEvent): void {
    if (!dragOrigin) return;
    pendingMove = { clientX: e.clientX, clientY: e.clientY, shiftKey: e.shiftKey };
    moveFrame.schedule(flushMove);
  }

  function flushMove(): void {
    const m = pendingMove;
    pendingMove = null;
    if (!m || !dragOrigin) return;
    const p = toImagePoint(m.clientX, m.clientY);
    const tool = screenshotEditor.tool;

    if (activeHandle && screenshotEditor.selectedId) {
      screenshotEditor.resizeSelected(activeHandle, p.x - dragOrigin.x, p.y - dragOrigin.y);
      dragOrigin = p;
      return;
    }
    if (activeCropHandle && screenshotEditor.crop) {
      const c = screenshotEditor.crop;
      const dx = p.x - dragOrigin.x;
      const dy = p.y - dragOrigin.y;
      let { x, y, w, h } = c;
      if (activeCropHandle.includes("w")) { x += dx; w -= dx; }
      if (activeCropHandle.includes("e")) { w += dx; }
      if (activeCropHandle.includes("n")) { y += dy; h -= dy; }
      if (activeCropHandle.includes("s")) { h += dy; }
      screenshotEditor.setCrop({ x, y, w, h });
      dragOrigin = p;
      return;
    }

    if (tool === "select" && movingId) {
      const dx = p.x - dragOrigin.x;
      const dy = p.y - dragOrigin.y;
      screenshotEditor.setAnnotations(
        screenshotEditor.annotations.map((a) => (a.id === movingId ? moveAnnotation(a, dx, dy) : a)),
      );
      dragOrigin = p;
      return;
    }
    if (tool === "crop" && screenshotEditor.crop) {
      const c = screenshotEditor.crop;
      screenshotEditor.setCrop({ ...c, w: p.x - c.x, h: p.y - c.y });
      return;
    }
    if (drafting) {
      if (drafting.type === "draw") {
        strokePoints.push(p);
        const b = strokeBounds;
        if (p.x < b.minX) b.minX = p.x;
        if (p.y < b.minY) b.minY = p.y;
        if (p.x > b.maxX) b.maxX = p.x;
        if (p.y > b.maxY) b.maxY = p.y;
        drafting = { ...drafting, box: { x: b.minX, y: b.minY, w: b.maxX - b.minX, h: b.maxY - b.minY } };
      } else if (m.shiftKey && drafting.type === "arrow") {
        // Shift turns an arrow to 15 degree steps and keeps a shape square.
        const end = snapAngle(dragOrigin, p);
        drafting = { ...drafting, box: { ...drafting.box, w: end.x - dragOrigin.x, h: end.y - dragOrigin.y } };
      } else if (m.shiftKey && (drafting.type === "rect" || drafting.type === "ellipse")) {
        const side = Math.max(Math.abs(p.x - dragOrigin.x), Math.abs(p.y - dragOrigin.y));
        drafting = { ...drafting, box: { ...drafting.box, w: Math.sign(p.x - dragOrigin.x || 1) * side, h: Math.sign(p.y - dragOrigin.y || 1) * side } };
      } else {
        drafting = { ...drafting, box: { ...drafting.box, w: p.x - dragOrigin.x, h: p.y - dragOrigin.y } };
      }
    }
  }

  function onPointerUp(): void {
    moveFrame.cancel();
    flushMove(); // apply the final pointer position before committing
    if (activeHandle) { screenshotEditor.pushHistory(); activeHandle = null; dragOrigin = null; return; }
    if (activeCropHandle && screenshotEditor.crop) { screenshotEditor.setCrop(normalizeBox(screenshotEditor.crop)); activeCropHandle = null; dragOrigin = null; return; }
    const tool = screenshotEditor.tool;
    if (tool === "select" && movingId) {
      screenshotEditor.pushHistory();
    } else if (tool === "crop" && screenshotEditor.crop) {
      cropping = false;
      // A click, not a drag: no crop rather than an invisible one with its actions floating.
      const c = normalizeBox(screenshotEditor.crop);
      screenshotEditor.setCrop(c.w >= 3 && c.h >= 3 ? c : null);
    } else if (drafting) {
      if (drafting.type === "draw") {
        const pts = drafting.points ?? [];
        const b = boundsOfPoints(pts);
        const significant = pts.length >= 2 && (b.w >= 3 || b.h >= 3);
        if (significant) screenshotEditor.commit([...screenshotEditor.annotations, { ...drafting, box: b }]);
      } else {
        // Arrows keep their raw direction (normalizing would flip an up-left arrow); only box-shaped
        // annotations get a positive-origin box. Threshold uses length so a straight arrow still counts.
        const isArrow = drafting.type === "arrow";
        const box = isArrow ? drafting.box : normalizeBox(drafting.box);
        const significant = isArrow
          ? Math.hypot(box.w, box.h) >= 6
          : Math.abs(box.w) >= 3 && Math.abs(box.h) >= 3;
        if (significant) screenshotEditor.commit([...screenshotEditor.annotations, { ...drafting, box }]);
      }
    }
    drafting = null;
    dragOrigin = null;
    movingId = null;
  }

  // The shared drawing keys, then the editor's own.
  const SHORTCUTS: Record<string, Annotation["type"] | "select" | "crop"> = {
    [SHARED_TOOL_KEYS.select.toLowerCase()]: "select", [SHARED_TOOL_KEYS.arrow.toLowerCase()]: "arrow",
    [SHARED_TOOL_KEYS.rect.toLowerCase()]: "rect", [SHARED_TOOL_KEYS.ellipse.toLowerCase()]: "ellipse",
    [SHARED_TOOL_KEYS.text.toLowerCase()]: "text", [SHARED_TOOL_KEYS.pen.toLowerCase()]: "draw",
    h: "highlight", b: "blur", n: "badge", c: "crop",
  };

  function onKeydown(e: KeyboardEvent): void {
    // While editing text the input owns the keyboard: never treat letters as tool shortcuts.
    if (screenshotEditor.editingTextId || e.defaultPrevented) return;
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") {
      e.preventDefault();
      if (e.shiftKey) { screenshotEditor.redo(); } else { screenshotEditor.undo(); }
      return;
    }
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") {
      e.preventDefault();
      void (e.shiftKey ? screenshotEditor.saveAs() : screenshotEditor.save());
      return;
    }
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "c" && !screenshotEditor.selectedId) { e.preventDefault(); void screenshotEditor.copy(); return; }
    if (e.key === "Escape") {
      e.preventDefault();
      // Escape clears a pending crop first; otherwise it cancels the whole editor.
      if (screenshotEditor.crop) { screenshotEditor.setCrop(null); } else { screenshotEditor.cancel(); }
      return;
    }
    if (e.key === "Backspace" || e.key === "Delete") { e.preventDefault(); screenshotEditor.deleteSelected(); return; }
    const tool = SHORTCUTS[e.key.toLowerCase()];
    if (tool) screenshotEditor.setTool(tool);
  }
</script>

<svelte:window onkeydown={screenshotEditor.open ? onKeydown : undefined} />

{#if screenshotEditor.open && (captured || screenshotEditor.loading)}
  <div
    class="screenshot-editor chrome-content-overlay-root"
    class:sidebar-hidden={!isSidebarVisible()}
    role="dialog"
    aria-label={t("screenshot.editor")}
    use:reportInteractiveZone={{ id: "screenshot-editor", active: screenshotEditor.open }}
  >
    <div class="backdrop" transition:fade={{ duration: prefersReducedMotion() ? 0 : 220 }}></div>

    {#if screenshotEditor.loading || !captured}
      <div class="capture-loading" role="status" transition:fade={{ duration: prefersReducedMotion() ? 0 : 160 }}>
        <ExtensionSpinner />
        {t("screenshot.capturing")}
      </div>
      <!-- Decoded off screen first, so the editor opens on a ready image and its liftoff plays. -->
      {#if captured}
        <img
          class="preload"
          src={captured.url}
          crossorigin="anonymous"
          alt=""
          onload={(e) => void (e.currentTarget as HTMLImageElement).decode().catch(() => {}).then(() => screenshotEditor.imageReady())}
          onerror={() => screenshotEditor.imageReady()}
        />
      {/if}
    {:else}
    <div class="stage" class:tall={tall}>
      <div
        class="canvas"
        role="application"
        aria-label={t("screenshot.canvas")}
        bind:this={canvasEl}
        bind:clientWidth={canvasW}
        transition:liftoff
        onpointerdown={onPointerDown}
        onpointermove={onPointerMove}
        onpointerup={onPointerUp}
        onpointercancel={onPointerUp}
        ondblclick={onDblClick}
      >
        <img bind:this={baseImage} class="base" src={captured.url} crossorigin="anonymous" alt={t("screenshot.title")} draggable="false" onload={onImageLoad} />

        {#each [...blurRegions, ...(drafting && drafting.type === "blur" ? [drafting] : [])] as b (b.id)}
          {@const n = normalizeBox(b.box)}
          {@const bw = Math.max(1, n.w)}
          {@const bh = Math.max(1, n.h)}
          <div
            class="blur-region"
            style={`filter:blur(${natW ? (BLUR_RADIUS_PX * canvasW) / natW : 0}px); left:${(n.x / natW) * 100}%; top:${(n.y / natH) * 100}%; width:${(n.w / natW) * 100}%; height:${(n.h / natH) * 100}%; background-image:url('${captured.url}'); background-size:${(natW / bw) * 100}% ${(natH / bh) * 100}%; background-position:${natW - bw > 0 ? (n.x / (natW - bw)) * 100 : 0}% ${natH - bh > 0 ? (n.y / (natH - bh)) * 100 : 0}%;`}
          ></div>
        {/each}

        <svg bind:this={svgEl} class="anno-layer" viewBox={`0 0 ${natW} ${natH}`} preserveAspectRatio="none">
          {#each [...vectorAnnotations, ...(drafting && drafting.type !== "blur" ? [drafting] : [])] as a (a.id)}
            {@const n = normalizeBox(a.box)}
            {#if a.type === "draw"}
              <path d={smoothPath(a.points ?? [])} fill="none" stroke={a.color} stroke-width={a.strokeWidth} stroke-dasharray={dashArray(a.dash, a.strokeWidth)} stroke-linecap="round" stroke-linejoin="round" />
            {:else if a.type === "rect"}
              <rect x={n.x} y={n.y} width={n.w} height={n.h} fill={a.fill && a.fill !== "none" ? a.color : "none"} fill-opacity={a.fill === "solid" ? 1 : 0.16} stroke={a.color} stroke-width={a.strokeWidth} stroke-dasharray={dashArray(a.dash, a.strokeWidth)} stroke-linecap="round" />
            {:else if a.type === "ellipse"}
              <ellipse cx={n.x + n.w / 2} cy={n.y + n.h / 2} rx={n.w / 2} ry={n.h / 2} fill={a.fill && a.fill !== "none" ? a.color : "none"} fill-opacity={a.fill === "solid" ? 1 : 0.16} stroke={a.color} stroke-width={a.strokeWidth} stroke-dasharray={dashArray(a.dash, a.strokeWidth)} stroke-linecap="round" />
            {:else if a.type === "highlight"}
              <rect x={n.x} y={n.y} width={n.w} height={n.h} fill={a.color} opacity="0.35" />
            {:else if a.type === "arrow"}
              {@const d = arrowPath({ x: a.box.x, y: a.box.y }, { x: a.box.x + a.box.w, y: a.box.y + a.box.h }, { x: 0, y: 0 }, a.strokeWidth, a.heads ?? "end")}
              <path d={d.shaft} fill="none" stroke={a.color} stroke-width={a.strokeWidth} stroke-dasharray={dashArray(a.dash, a.strokeWidth)} stroke-linecap="round" />
              <path d={d.heads} fill="none" stroke={a.color} stroke-width={a.strokeWidth} stroke-linecap="round" stroke-linejoin="round" />
            {:else if a.type === "text" && a.id !== screenshotEditor.editingTextId}
              <text x={n.x} y={n.y} dominant-baseline="hanging" fill={a.color} font-size={Math.max(16, a.strokeWidth * 6)} font-family="-apple-system, sans-serif">{a.text}</text>
            {:else if a.type === "badge"}
              {@const bcx = n.x + n.w / 2}
              {@const bcy = n.y + n.h / 2}
              {@const br = Math.min(n.w, n.h) / 2}
              <circle cx={bcx} cy={bcy} r={br} fill={a.color} />
              <text x={bcx} y={bcy} text-anchor="middle" dominant-baseline="central" fill="#fff" font-size={br * 1.2} font-weight="700" font-family="-apple-system, sans-serif">{a.text}</text>
            {/if}
          {/each}
          <!-- Crisp dashed outline only while DRAWING a blur (the HTML blur div has no visible
               border once blurred); the outline disappears once the blur is placed. -->
          {#if drafting && drafting.type === "blur"}
            {@const n = normalizeBox(drafting.box)}
            <rect x={n.x} y={n.y} width={n.w} height={n.h} fill="none" stroke="#fff" stroke-width="2" stroke-dasharray="6 4" vector-effect="non-scaling-stroke" />
          {/if}
          <!-- Crisp (un-blurred) outline for a re-selected blur, so its zone is visible again. -->
          {#if selectedAnnotation && selectedAnnotation.type === "blur"}
            {@const n = normalizeBox(selectedAnnotation.box)}
            <rect x={n.x} y={n.y} width={n.w} height={n.h} fill="none" style="stroke: var(--accent)" stroke-width="2" stroke-dasharray="6 4" vector-effect="non-scaling-stroke" />
          {/if}
        </svg>

        {#if selectedAnnotation}
          {@const s = normalizeBox(selectedAnnotation.box)}
          {@const L = (s.x / natW) * 100}
          {@const T = (s.y / natH) * 100}
          {@const W = (s.w / natW) * 100}
          {@const Hp = (s.h / natH) * 100}
          <div class="sel-box" style={`left:${L}%; top:${T}%; width:${W}%; height:${Hp}%;`}></div>
          {#if selectedAnnotation.type !== "draw"}
            {#each HANDLES as hd (hd.h)}
              <div
                class="sel-handle"
                role="button"
                aria-label={t("screenshot.resizeHandle", { handle: hd.h })}
                tabindex="-1"
                style={`left:${L + hd.fx * W}%; top:${T + hd.fy * Hp}%; cursor:${hd.h}-resize;`}
                onpointerdown={(e) => onHandleDown(e, hd.h)}
              ></div>
            {/each}
          {/if}
          <button
            class="sel-delete"
            style={`left:${L + W}%; top:${T}%;`}
            aria-label={t("common.delete")}
            onpointerdown={(e) => e.stopPropagation()}
            onclick={() => screenshotEditor.deleteSelected()}
          >
            <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8" /></svg>
          </button>
        {/if}

        {#if screenshotEditor.crop}
          {@const c = normalizeBox(screenshotEditor.crop)}
          <div
            class="crop-frame"
            class:applied={screenshotEditor.cropApplied}
            style={`left:${natW ? (c.x / natW) * 100 : 0}%; top:${natH ? (c.y / natH) * 100 : 0}%; width:${natW ? (c.w / natW) * 100 : 0}%; height:${natH ? (c.h / natH) * 100 : 0}%;`}
          ></div>
          {#if !screenshotEditor.cropApplied}
            {#each HANDLES as hd (hd.h)}
              <div
                class="sel-handle"
                role="button"
                aria-label={t("screenshot.cropHandle", { handle: hd.h })}
                tabindex="-1"
                style={`left:${((c.x / natW) * 100) + hd.fx * (c.w / natW) * 100}%; top:${((c.y / natH) * 100) + hd.fy * (c.h / natH) * 100}%; cursor:${hd.h}-resize;`}
                onpointerdown={(e) => onCropHandleDown(e, hd.h)}
              ></div>
            {/each}
          {/if}
          {#if !cropping && !screenshotEditor.cropApplied}
            <div
              class="crop-actions"
              role="group"
              aria-label={t("screenshot.cropActions")}
              style={`left:${natW ? ((c.x + c.w) / natW) * 100 : 0}%; top:${natH ? ((c.y + c.h) / natH) * 100 : 0}%;`}
              onpointerdown={(e) => e.stopPropagation()}
            >
              <button class="crop-btn apply" title={t("screenshot.applyCrop")} aria-label={t("screenshot.applyCrop")} onclick={() => screenshotEditor.applyCrop()}>
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8.5l3.5 3.5L13 4.5" /></svg>
              </button>
              <button class="crop-btn clear" title={t("screenshot.clearCrop")} aria-label={t("screenshot.clearCrop")} onclick={() => screenshotEditor.setCrop(null)}>
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8" /></svg>
              </button>
            </div>
          {/if}
        {/if}

        {#if editingAnnotation}
          <input
            class="text-input"
            value={editingAnnotation.text ?? ""}
            style={`left:${natW ? (editingAnnotation.box.x / natW) * 100 : 0}%; top:${natH ? (editingAnnotation.box.y / natH) * 100 : 0}%; color:${editingAnnotation.color}; font-size:${Math.max(16, editingAnnotation.strokeWidth * 6) * editScale}px;`}
            oninput={(e) => screenshotEditor.setEditingText((e.currentTarget as HTMLInputElement).value)}
            onkeydown={onTextKeydown}
            onpointerdown={(e) => e.stopPropagation()}
            onblur={() => screenshotEditor.commitTextEdit()}
            use:focusOnMount
          />
        {/if}
      </div>
    </div>
    {/if}
  </div>
{/if}

{#if screenshotEditor.toast}
  <!-- Centered on the page, not the window: a narrow window's sidebar stays uncovered. -->
  <div class="screenshot-toast-host chrome-content-overlay-root" class:sidebar-hidden={!isSidebarVisible()}>
    <div
      class="screenshot-toast"
      class:error={screenshotEditor.toast.kind === "error"}
      use:reportInteractiveZone={{ id: "screenshot-toast" }}
    >
      {screenshotEditor.toast.kind === "saved" ? t("screenshot.savedTo", { path: screenshotEditor.toast.message }) : screenshotEditor.toast.message}
      <button onclick={() => screenshotEditor.clearToast()} aria-label={t("common.close")}>×</button>
    </div>
  </div>
{/if}

<style>
  /* Positioning comes from .chrome-content-overlay-root (fixed to the content region). */
  .screenshot-editor { z-index: 1000; overflow: hidden; pointer-events: auto; }
  /* Near-opaque: the live (often white) page sits behind this overlay, and a translucent backdrop
     would let it bleed through as a pale "margin" around the capture. */
  .backdrop { position: absolute; inset: 0; background: rgba(10, 11, 13, 0.97); }
  .capture-loading { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; gap: 10px; color: #e8eaee; font-size: var(--font-size-md); }
  .preload { position: absolute; width: 1px; height: 1px; opacity: 0; pointer-events: none; }

  /* Stage fills the overlay and centers the canvas; padding gives the framed margin. */
  .stage { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; padding: 12px; }
  /* Canvas wraps the image exactly; SVG + blur + crop overlay it 1:1. */
  /* align-items:center stops the flex cross-axis from stretching the base image
     (distorted aspect ratio on wide "visible area" captures) while keeping the
     canvas sized exactly to the image so overlays stay aligned. */
  .canvas { position: relative; display: flex; align-items: center; max-width: 100%; max-height: 100%; cursor: crosshair; }
  .stage.tall { align-items: flex-start; overflow-y: auto; overflow-x: hidden; padding: 16px 28px; }
  .stage.tall .canvas { max-width: 100%; max-height: none; }
  .stage.tall .base { max-width: 100%; max-height: none; width: 100%; height: auto; }
  .base { display: block; max-width: 100%; max-height: 100%; width: auto; height: auto; user-select: none; border-radius: var(--radius-sm); box-shadow: 0 16px 40px rgba(0, 0, 0, 0.55); }
  .anno-layer { position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none; }
  .blur-region {
    position: absolute; border-radius: var(--radius-2xs); pointer-events: none;
    background-repeat: no-repeat;
  }
  .crop-frame { position: absolute; border: 1.5px dashed #fff; box-shadow: 0 0 0 9999px rgba(10, 11, 13, 0.45); pointer-events: none; }
  /* Once applied, everything outside the crop is fully hidden: only the crop zone shows. */
  .crop-frame.applied { border-color: transparent; box-shadow: 0 0 0 9999px #0a0b0d; }
  .sel-box { position: absolute; border: 1px dashed var(--accent); pointer-events: none; box-sizing: border-box; }
  .sel-handle { position: absolute; width: 10px; height: 10px; transform: translate(-50%, -50%); background: #fff; border: 1.5px solid var(--accent); border-radius: var(--radius-2xs); touch-action: none; }
  .sel-delete { position: absolute; transform: translate(6px, -100%); width: 22px; height: 22px; display: grid; place-items: center; border: none; border-radius: var(--radius-sm); background: #ff3b30; color: #fff; cursor: pointer; }
  .crop-actions {
    position: absolute; transform: translate(-100%, 8px); display: flex; gap: 4px; padding: 4px;
    background: rgba(28, 30, 36, 0.96); border: 1px solid rgba(255, 255, 255, 0.12); border-radius: var(--radius-md);
    box-shadow: 0 6px 20px rgba(0, 0, 0, 0.5);
  }
  .crop-btn { width: 28px; height: 28px; border: none; border-radius: var(--radius-sm); display: grid; place-items: center; cursor: pointer; background: rgba(255, 255, 255, 0.08); color: #e8eaee; }
  .crop-btn.apply { background: var(--accent); color: var(--accent-text); }
  .crop-btn:hover { filter: brightness(1.12); }

  .text-input {
    position: absolute; transform: translateY(-2px); margin: 0; padding: 0 2px;
    border: 1px dashed rgba(0, 0, 0, 0.35); background: rgba(255, 255, 255, 0.5);
    font-family: -apple-system, sans-serif; line-height: 1.1;
    outline: none; min-width: 40px; border-radius: var(--radius-2xs);
  }

  .screenshot-toast-host { z-index: 1001; display: flex; align-items: flex-end; justify-content: center; padding: 0 16px 16px; pointer-events: none; }
  .screenshot-toast {
    pointer-events: auto; max-width: 100%;
    display: flex; gap: 12px; align-items: center;
    padding: 10px 14px; border-radius: var(--radius-md); font-size: var(--font-size-sm); color: #e8eaee;
    background: rgba(38, 40, 46, 0.98); border: 1px solid rgba(255, 255, 255, 0.1);
    box-shadow: 0 8px 26px rgba(0, 0, 0, 0.55);
  }
  .screenshot-toast.error { border-color: rgba(255, 80, 70, 0.6); }
  .screenshot-toast button { border: none; background: transparent; color: inherit; cursor: pointer; font-size: var(--font-size-lg); }
</style>
