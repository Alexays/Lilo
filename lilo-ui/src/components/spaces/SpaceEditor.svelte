<script lang="ts">
  import { tick, untrack } from "svelte";
  import { scale } from "svelte/transition";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import BottomConfirmSheet from "../ui/BottomConfirmSheet.svelte";
  import { getAgentsProfileId, getAgentsSpaceId } from "../../stores/agents.svelte";
  import { getProfileById, getProfileExtensionCounts, getProfiles } from "../../stores/profiles.svelte";
  import { getSpaces } from "../../stores/spaces.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import { profileActions, spaceActions } from "../../lib/bridge/actions";
  import PanelHeader from "../ui/PanelHeader.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiSelect from "../ui/UiSelect.svelte";
  import { nextProfileColor, PASTEL_COLORS, spacesByProfile, userProfiles } from "../settings/profilesModel";
  import {
    canSave,
    initialProfileChoice,
    spaceEditorSubmission,
    type ProfileChoice,
  } from "./spaceEditorModel";
  import {
    closeEditor,
    editorState,
    isEditorOpen,
    openSettings,
    revealSetting,
    updateEditorState,
  } from "../../stores/panels.svelte";

  const RECOMMENDED_SPACE_EMOJIS = [
    "🏠",
    "💼",
    "📚",
    "🎧",
    "✈️",
    "🛍️",
    "💬",
    "🌿",
    "🎮",
    "⭐",
    "🔒",
  ];

  let showEmojiPopover = $state(false);
  // The quick picks' ··· tile widens the popover into the full picker, loaded on first use.
  let showFullPicker = $state(false);
  let emojiButton: HTMLButtonElement | undefined = $state();
  let moreButton: HTMLButtonElement | undefined = $state();
  let showDeleteConfirmSheet = $state(false);
  let choice = $state<ProfileChoice>({ kind: "profile", id: "" });
  let newProfileName = $state("");

  const users = $derived(userProfiles(getProfiles(), getAgentsProfileId()));
  const usage = $derived(spacesByProfile(getSpaces(), getAgentsSpaceId()));
  const extensionCounts = $derived(getProfileExtensionCounts());
  // What the "New profile" choice will wear: the color Swift would pick, sent along explicitly.
  const newProfileColor = $derived(nextProfileColor(getProfiles()));
  const editingSpace = $derived(getSpaces().find((space) => space.id === editorState().spaceId));
  const editingPrivate = $derived(editorState().mode === "edit" && editingSpace?.isPrivate === true);
  const archiveOptions = $derived(
    [
      ["12", "spaceEditor.archive12Hours"],
      ["24", "spaceEditor.archive24Hours"],
      ["168", "spaceEditor.archive7Days"],
      ["720", "spaceEditor.archive30Days"],
      ["0", "spaceEditor.archiveNever"],
    ].map(([value, key]) => ({ value, label: t(key) })),
  );
  const saveEnabled = $derived(canSave(editorState().name, choice, newProfileName));
  // Deleting the only space would leave the window empty.
  const isLastSpace = $derived(getSpaces().length <= 1);
  const customColor = $derived(!PASTEL_COLORS.includes(editorState().color));

  const hint = $derived.by(() => {
    if (choice.kind === "private") return t("spaceEditor.hintPrivate");
    if (choice.kind === "new") return t("spaceEditor.hintNew");
    const others = (usage.get(choice.id) ?? []).filter((space) => space.id !== editorState().spaceId);
    return others.length > 0
      ? t("spaceEditor.hintShared", { spaces: others.map((space) => space.name).join(", ") })
      : t("spaceEditor.hintOwn");
  });

  // Every edit replaces the editor state: the choice is seeded only when the edited space changes.
  const editorKey = $derived(`${editorState().mode}:${editorState().spaceId}`);
  $effect(() => {
    void editorKey;
    untrack(() => {
      choice = initialProfileChoice(editorState(), editingPrivate, users);
      newProfileName = "";
      showDeleteConfirmSheet = false;
    });
  });

  // The chosen profile vanished (removed in another window): fall back to the default one.
  $effect(() => {
    if (choice.kind === "profile" && choice.id && !getProfileById(choice.id)) {
      choice = initialProfileChoice({ ...untrack(editorState), mode: "add", profileId: "" }, false, users);
    }
  });

  $effect(() => {
    profileActions.loadStats();
  });

  $effect(() => {
    if (!showEmojiPopover) {
      return;
    }

    const handlePointerDown = (event: PointerEvent) => {
      const target = event.target as HTMLElement | null;
      if (target?.closest(".emoji-picker-shell")) {
        return;
      }

      closeEmojiPopover(false);
    };

    window.addEventListener("pointerdown", handlePointerDown, true);

    return () => {
      window.removeEventListener("pointerdown", handlePointerDown, true);
    };
  });

  function identityTint(color: string): string {
    return [
      `background: linear-gradient(135deg,`,
      `color-mix(in srgb, ${color} 52%, var(--bg-primary)),`,
      `color-mix(in srgb, ${color} 20%, var(--bg-primary)))`,
    ].join(" ");
  }

  function profileMeta(id: string): string {
    const names = (usage.get(id) ?? []).map((space) => space.name).join(", ");
    const count = extensionCounts?.[id] ?? (extensionCounts ? 0 : null);
    return [
      names || t("settings.profiles.noSpace"),
      count === null
        ? ""
        : count === 1
          ? t("settings.profiles.extensionCountOne")
          : t("settings.profiles.extensionCount", { count }),
    ]
      .filter(Boolean)
      .join(" · ");
  }

  function save() {
    const s = editorState();
    if (!canSave(s.name, choice, newProfileName)) return;
    showDeleteConfirmSheet = false;
    const submission = spaceEditorSubmission(s, choice, { name: newProfileName, color: newProfileColor });
    if (submission.action === "createSpace") spaceActions.create(submission.payload);
    else spaceActions.update(submission.payload);
    closeEditor();
  }

  function manageProfiles() {
    openSettings("tabs");
    revealSetting("tabs", "newProfile");
  }

  function openDeleteConfirmSheet() {
    const s = editorState();
    if (s.mode !== "edit" || isLastSpace) return;
    showDeleteConfirmSheet = true;
  }

  function confirmDeleteSpace() {
    const s = editorState();
    if (s.mode !== "edit" || isLastSpace) return;
    spaceActions.delete(s.spaceId);
    showDeleteConfirmSheet = false;
    closeEditor();
  }

  function closeEmojiPopover(refocus: boolean) {
    showEmojiPopover = false;
    showFullPicker = false;
    if (refocus) emojiButton?.focus();
  }

  // The full picker's Recent: the last 16 picks from either grid, newest first.
  function selectEmoji(icon: string) {
    updateEditorState({ icon });
    const recent = getSetting("emojiRecent", "").split(" ").filter((emoji) => emoji && emoji !== icon);
    setSetting("emojiRecent", [icon, ...recent].slice(0, 16).join(" "));
    closeEmojiPopover(true);
  }

  async function closeFullPicker() {
    showFullPicker = false;
    await tick();
    moreButton?.focus();
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.defaultPrevented) return;
    if (e.key === "Escape") {
      e.preventDefault();
      if (showEmojiPopover) {
        closeEmojiPopover(true);
        return;
      }
      closeEditor();
      return;
    }
    // The delete confirmation's own buttons take Return: its focused Cancel must never delete.
    if (showDeleteConfirmSheet) return;
    // Command-Return submits from anywhere; plain Return only from a text field, where it
    // would otherwise do nothing.
    const inTextField = e.target instanceof HTMLInputElement && e.target.type === "text";
    if (e.key === "Enter" && (e.metaKey || inTextField)) {
      e.preventDefault();
      save();
    }
  }
</script>

{#snippet profileRow(p: {
  kind: "profile" | "new" | "private";
  color?: string;
  checked: boolean;
  select: () => void;
  label: string;
  detail: string;
})}
  <button
    class="profile-choice"
    role="radio"
    aria-checked={p.checked}
    onclick={p.select}
  >
    {#if p.kind === "new"}
      <span class="choice-avatar new" aria-hidden="true">+</span>
    {:else if p.kind === "private"}
      <span class="choice-avatar private" aria-hidden="true">
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
          <circle cx="8" cy="8" r="5.75" stroke="currentColor" stroke-width="1.5" />
          <path d="M8 2.25a5.75 5.75 0 0 1 0 11.5z" fill="currentColor" />
        </svg>
      </span>
    {:else}
      <span class="choice-avatar" aria-hidden="true"><span class="choice-dot" style:background={p.color}></span></span>
    {/if}
    <span class="choice-copy">
      <span class="choice-name">{p.label}</span>
      <span class="choice-detail">{p.detail}</span>
    </span>
    <span class="choice-check" aria-hidden="true"></span>
  </button>
{/snippet}

{#if isEditorOpen()}
  {@const s = editorState()}
  <div
    class="panel-shell editor-panel"
    role="dialog"
    aria-label={t("spaceEditor.dialogLabel")}
    tabindex="0"
    onkeydown={handleKeydown}
  >
    <PanelHeader
      title={s.mode === "add" ? t("spaceEditor.newSpace") : t("spaceEditor.editSpace")}
      onclose={closeEditor}
    />

    <div class="editor-body">
      <div class="preview-card" style={identityTint(s.color)}>
        <div class="identity-row">
          <div class="emoji-picker-shell">
            <button
              class="space-emoji-btn"
              class:active={showEmojiPopover}
              bind:this={emojiButton}
              onclick={() => (showEmojiPopover ? closeEmojiPopover(false) : (showEmojiPopover = true))}
              aria-label={t("spaceEditor.chooseSpaceEmoji")}
              aria-expanded={showEmojiPopover}
              aria-haspopup="dialog"
              use:tooltip={t("spaceEditor.chooseSpaceEmoji")}
            >
              <span class="space-emoji-glyph">{s.icon || "🌐"}</span>
              <span class="space-emoji-badge" aria-hidden="true">✎</span>
            </button>

            {#if showEmojiPopover}
              <div
                class="emoji-popover"
                class:full={showFullPicker}
                role="dialog"
                aria-label={t("spaceEditor.chooseEmoji")}
                transition:scale={{ start: 0.92, duration: prefersReducedMotion() ? 0 : 120 }}
              >
                {#if showFullPicker}
                  {#await import("./EmojiPicker.svelte") then { default: EmojiPicker }}
                    <EmojiPicker selected={s.icon} onpick={selectEmoji} onclose={closeFullPicker} />
                  {/await}
                {:else}
                  <div class="emoji-popover-header">
                    <strong>{t("spaceEditor.recommended")}</strong>
                    <span>{t("spaceEditor.quickPicks")}</span>
                  </div>

                  <div class="emoji-grid">
                    {#each RECOMMENDED_SPACE_EMOJIS as emoji (emoji)}
                      <button
                        class="emoji-choice"
                        class:selected={s.icon === emoji}
                        onclick={() => selectEmoji(emoji)}
                        title={emoji}
                      >
                        {emoji}
                      </button>
                    {/each}
                    <button
                      class="emoji-choice emoji-more"
                      bind:this={moreButton}
                      onclick={() => (showFullPicker = true)}
                      use:tooltip={t("spaceEditor.moreEmojis")}
                      aria-label={t("spaceEditor.moreEmojis")}
                    >
                      ···
                    </button>
                  </div>
                {/if}
              </div>
            {/if}
          </div>

          <input
            class="identity-name-input"
            type="text"
            value={s.name}
            placeholder={t("spaceEditor.spaceNamePlaceholder")}
            aria-label={t("spaceEditor.spaceNamePlaceholder")}
            spellcheck="false"
            oninput={(e) => updateEditorState({ name: (e.currentTarget as HTMLInputElement).value })}
          />
        </div>

      </div>

      <div class="field">
        <span class="field-label">{t("spaceEditor.colorLabel")}</span>
        <div class="color-grid">
          {#each PASTEL_COLORS as c, index (c)}
            <button
              class="color-swatch"
              class:selected={s.color === c}
              style:background={c}
              onclick={() => updateEditorState({ color: c })}
              aria-label={t("common.colorSwatch", { number: String(index + 1) })}
              aria-pressed={s.color === c}
            ></button>
          {/each}
          <!-- WebKit opens the macOS color panel for a color input. -->
          <label
            class="color-swatch custom"
            class:selected={customColor}
            style:background={customColor ? s.color : null}
            use:tooltip={t("spaceEditor.customColor")}
          >
            <input
              type="color"
              aria-label={t("spaceEditor.customColor")}
              value={s.color}
              oninput={(e) => updateEditorState({ color: (e.currentTarget as HTMLInputElement).value })}
            />
          </label>
        </div>
      </div>

      <div class="field">
        <div class="field-label-row">
          <span class="field-label">{t("spaceEditor.signedInAs")}</span>
          <button class="manage-link" onclick={manageProfiles}>{t("spaceEditor.manageProfiles")}</button>
        </div>
        <div class="profile-choices" role="radiogroup" aria-label={t("spaceEditor.signedInAs")}>
          {#if !editingPrivate}
            {#each users as profile (profile.id)}
              {@render profileRow({
                kind: "profile",
                color: profile.color,
                checked: choice.kind === "profile" && choice.id === profile.id,
                select: () => (choice = { kind: "profile", id: profile.id }),
                label: profile.name,
                detail: profileMeta(profile.id),
              })}
            {/each}
            {@render profileRow({
              kind: "new",
              checked: choice.kind === "new",
              select: () => (choice = { kind: "new" }),
              label: t("settings.profiles.newProfile"),
              detail: t("spaceEditor.newProfileDetail"),
            })}
            {#if choice.kind === "new"}
              <input
                class="new-profile-input"
                type="text"
                {@attach (node) => node.focus()}
                bind:value={newProfileName}
                placeholder={t("spaceEditor.profileNamePlaceholder")}
                aria-label={t("spaceEditor.profileNamePlaceholder")}
                spellcheck="false"
              />
            {/if}
          {/if}
          {#if s.mode === "add" || editingPrivate}
            {@render profileRow({
              kind: "private",
              checked: choice.kind === "private",
              select: () => (choice = { kind: "private" }),
              label: t("spaceEditor.private"),
              detail: t("spaceEditor.privateDetail"),
            })}
          {/if}
        </div>
        <p class="field-hint">{hint}</p>
      </div>

      <!-- Per-Space settings: one .field each, below the profile choice. -->
      {#if s.mode === "edit"}
        <div class="field">
          <span class="field-label">{t("spaceEditor.archiveLabel")}</span>
          <UiSelect
            value={String(s.archiveAfterHours)}
            options={archiveOptions}
            ariaLabel={t("spaceEditor.archiveLabel")}
            onchange={(value) => updateEditorState({ archiveAfterHours: Number(value) })}
          />
          <p class="field-hint">{t("spaceEditor.archiveHelper")}</p>
        </div>
      {/if}
    </div>

    <div class="editor-footer">
      {#if s.mode === "edit" && isLastSpace}
        <!-- Tooltip on a wrapper span: disabled buttons swallow the pointer events. -->
        <span class="delete-space-wrap" use:tooltip={t("spaceEditor.lastSpaceHint")}>
          <UiButton variant="danger" disabled>{t("common.delete")}</UiButton>
        </span>
      {:else if s.mode === "edit"}
        <UiButton variant="danger" onclick={openDeleteConfirmSheet}>{t("common.delete")}</UiButton>
      {:else}
        <kbd class="submit-shortcut">⌘↩</kbd>
      {/if}
      <div class="footer-actions">
        <UiButton variant="ghost" onclick={closeEditor}>{t("common.cancel")}</UiButton>
        <UiButton variant="primary" disabled={!saveEnabled} onclick={save}>
          {s.mode === "add" ? t("spaceEditor.create") : t("common.save")}
        </UiButton>
      </div>
    </div>

    <BottomConfirmSheet
      visible={showDeleteConfirmSheet}
      title={t("spaceEditor.deleteConfirmTitle", {
        name: s.name || t("spaceEditor.thisSpace"),
      })}
      message={t("spaceEditor.deleteConfirmMessage")}
      confirmLabel={t("spaceEditor.deleteSpace")}
      cancelLabel={t("spaceEditor.keepSpace")}
      confirmAction={confirmDeleteSpace}
      cancelAction={() => (showDeleteConfirmSheet = false)}
    />
  </div>
{/if}

<style>
  /* The chrome theme follows the color being picked: the panel paints the sidebar and window frame color. */
  .editor-panel {
    position: relative;
    overflow: hidden;
    background: var(--sidebar-bg);
    transition: background var(--motion-duration-slow) var(--motion-ease-organic);
  }

  /* Sized to its content: the footer follows the last field instead of the panel's bottom. */
  .editor-body {
    flex: 0 1 auto;
    padding: 4px 16px 14px;
    display: flex;
    flex-direction: column;
    gap: 16px;
    min-height: 0;
    overflow-y: auto;
  }

  /* minmax(0, 1fr): the name input's intrinsic width would otherwise widen the card past a narrow sidebar. */
  .preview-card {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 6px;
    padding: 12px;
    border-radius: var(--radius-lg);
    border: 1px solid var(--text-primary-tint-10);
    transition: background var(--transition-fast);
  }

  /* Anchors the emoji popover, which spans the row so it stays inside the card at any sidebar width. */
  .identity-row {
    position: relative;
    display: flex;
    align-items: center;
    gap: 12px;
    margin-bottom: 4px;
  }

  .identity-name-input {
    flex: 1;
    min-width: 0;
    padding: 4px 2px;
    border: none;
    border-bottom: 1.5px dashed color-mix(in srgb, var(--text-primary) 35%, transparent);
    background: transparent;
    color: var(--text-primary);
    font-size: var(--font-size-xl);
    font-weight: var(--font-weight-bold);
    font-family: inherit;
    outline: none;
  }

  .identity-name-input::placeholder {
    color: color-mix(in srgb, var(--text-primary) 45%, transparent);
    font-weight: var(--font-weight-medium);
  }

  .identity-name-input:focus {
    border-bottom-color: var(--text-primary);
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .field-label-row {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
  }

  .field-label {
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .manage-link {
    padding: 0;
    border: 0;
    background: none;
    color: var(--text-secondary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
    cursor: pointer;
  }

  .manage-link:hover {
    color: var(--text-primary);
    text-decoration: underline;
  }

  .manage-link:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
    border-radius: var(--radius-xs);
  }

  /* minmax(0, 1fr): an auto column would grow to the name field's intrinsic width and push
     every row past the list at a narrow sidebar. */
  .profile-choices {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 2px;
    padding: 4px;
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--bg-primary) 45%, transparent);
  }

  .profile-choice {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 8px;
    border: 0;
    border-radius: var(--radius-md);
    background: transparent;
    color: var(--text-primary);
    font-family: inherit;
    text-align: left;
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .profile-choice:hover {
    background: color-mix(in srgb, var(--bg-primary) 55%, transparent);
  }

  .profile-choice[aria-checked="true"] {
    background: var(--bg-primary);
    box-shadow: var(--shadow-control);
  }

  .profile-choice:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .choice-avatar {
    flex: none;
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    border-radius: var(--radius-sm);
    font-size: var(--font-size-lg);
    font-weight: var(--font-weight-semibold);
  }

  .choice-dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
  }

  .choice-avatar.new {
    border: 1.5px dashed color-mix(in srgb, var(--text-primary) 30%, transparent);
    color: var(--text-secondary);
  }

  .choice-avatar.private {
    background: var(--text-primary);
    color: var(--bg-primary);
  }

  .choice-copy {
    display: grid;
    min-width: 0;
  }

  .choice-name {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
  }

  .choice-detail {
    overflow-wrap: anywhere;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .choice-check {
    flex: none;
    margin-left: auto;
    width: 16px;
    height: 16px;
    box-sizing: border-box;
    border-radius: 50%;
    border: 1.5px solid color-mix(in srgb, var(--text-primary) 25%, transparent);
    transition: border var(--transition-fast);
  }

  .profile-choice[aria-checked="true"] .choice-check {
    border: 5px solid var(--accent);
  }

  .new-profile-input {
    min-width: 0;
    margin: 0 8px 6px 44px;
    padding: 8px;
    border: 1px solid var(--border);
    border-radius: var(--radius-md);
    background: var(--bg-primary);
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-family: inherit;
  }

  .new-profile-input:focus {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .field-hint {
    margin: 0;
    padding: 0 4px;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.4;
  }

  .delete-space-wrap {
    display: inline-flex;
  }

  .emoji-picker-shell {
    flex-shrink: 0;
  }

  .space-emoji-btn {
    position: relative;
    width: 42px;
    height: 42px;
    border: 1px solid color-mix(in srgb, var(--text-primary) 14%, transparent);
    background: color-mix(in srgb, var(--bg-primary) 45%, transparent);
    border-radius: var(--radius-lg);
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    transition:
      border-color var(--transition-fast),
      background var(--transition-fast),
      transform var(--transition-fast),
      box-shadow var(--transition-fast);
  }

  .space-emoji-btn.active,
  .space-emoji-btn:hover {
    border-color: var(--accent);
    background: var(--bg-active);
  }

  .space-emoji-btn.active {
    box-shadow: 0 10px 20px var(--accent-tint-14);
  }

  .space-emoji-btn:hover {
    transform: translateY(-1px);
    box-shadow: 0 8px 18px var(--accent-tint-12);
  }

  .space-emoji-glyph {
    font-size: var(--font-size-3xl);
    line-height: 1;
  }

  .space-emoji-badge {
    position: absolute;
    right: -5px;
    bottom: -5px;
    width: 16px;
    height: 16px;
    border-radius: var(--radius-chip);
    background: var(--bg-primary);
    border: 1px solid var(--border);
    color: var(--text-secondary);
    font-size: var(--font-size-3xs);
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .emoji-popover {
    position: absolute;
    top: calc(100% + 10px);
    left: 0;
    width: 100%;
    max-width: 220px;
    box-sizing: border-box;
    padding: 12px;
    border-radius: var(--radius-xl);
    border: 1px solid var(--border);
    background: color-mix(in srgb, var(--bg-primary) 92%, white 8%);
    box-shadow: 0 18px 36px
      color-mix(in srgb, var(--text-primary) 16%, transparent);
    z-index: 12;
    backdrop-filter: blur(var(--chrome-floating-blur));
  }

  /* The identity row sits 29 px inside the panel (body padding, card padding and border): the full
     picker reaches out to 8 px from the panel's edges. */
  .emoji-popover.full {
    left: -21px;
    width: min(calc(100% + 42px), 340px);
    max-width: none;
    height: 318px;
    padding: var(--space-8);
  }

  .emoji-popover-header {
    display: flex;
    flex-direction: column;
    gap: 2px;
    margin-bottom: 10px;
  }

  .emoji-popover-header strong {
    font-size: var(--font-size-sm);
    color: var(--text-primary);
  }

  .emoji-popover-header span {
    font-size: var(--font-size-xs);
    color: var(--text-secondary);
  }

  .emoji-grid {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 6px;
  }

  .emoji-choice {
    min-width: 0;
    padding: 0;
    aspect-ratio: 1;
    border: 1px solid var(--border);
    border-radius: var(--radius-md);
    background: var(--bg-secondary);
    font-size: var(--font-size-2xl);
    cursor: pointer;
    transition:
      transform var(--transition-fast),
      background var(--transition-fast),
      border-color var(--transition-fast),
      box-shadow var(--transition-fast);
  }

  .emoji-choice:hover {
    transform: translateY(-1px);
    background: var(--bg-hover);
    border-color: var(--accent);
  }

  .emoji-choice.selected {
    background: var(--bg-active);
    border-color: var(--accent);
    box-shadow: 0 0 0 2px var(--accent-tint-18);
  }

  .emoji-more {
    font-size: var(--font-size-lg);
    font-weight: var(--font-weight-bold);
    color: var(--text-secondary);
  }

  /* Two rows of seven: the twelve presets and the custom picker. */
  .color-grid {
    display: grid;
    grid-template-columns: repeat(7, minmax(0, 1fr));
    gap: 8px;
  }

  .color-swatch {
    position: relative;
    aspect-ratio: 1;
    border: 1px solid var(--text-primary-tint-12);
    border-radius: 50%;
    cursor: pointer;
    transition:
      box-shadow var(--motion-duration-fast),
      border-color var(--motion-duration-fast),
      transform 0.12s;
    padding: 0;
    box-shadow: inset 0 0 0 1px color-mix(in srgb, white 22%, transparent);
  }
  .color-swatch.selected {
    border-color: var(--sidebar-swatch-ring, var(--text-primary));
    box-shadow:
      0 0 0 2px var(--accent-tint-22),
      inset 0 0 0 1px color-mix(in srgb, white 28%, transparent);
    transform: scale(1.1);
  }
  .color-swatch.selected::after {
    content: "✓";
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    color: color-mix(in srgb, black 55%, transparent);
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-bold);
  }
  .color-swatch:hover {
    transform: scale(1.1);
  }
  .color-swatch:focus-visible,
  .color-swatch.custom:focus-within {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .color-swatch.custom {
    overflow: hidden;
    background: var(--hue-wheel);
  }

  .color-swatch.custom input {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    padding: 0;
    border: 0;
    opacity: 0;
    cursor: pointer;
  }

  .editor-footer {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
    margin: 0 16px;
    padding: 10px 0 12px;
    border-top: 1px solid var(--border);
  }

  .footer-actions {
    display: flex;
    gap: 6px;
  }

  .submit-shortcut {
    color: var(--text-muted);
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: var(--font-size-xs);
  }
</style>
