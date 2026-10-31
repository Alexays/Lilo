<script lang="ts">
	import type { FolderState } from "../../stores/folders.svelte";
	import { t } from "../../lib/i18n/state.svelte";
	import { folderActions } from "../../lib/bridge/actions";
	import { on } from "../../lib/bridge";
	import { closeLockPanel, getLockPanel, openLockPanel } from "../../stores/folderLock.svelte";
	import { FOLDER_COLORS, folderColorStyle } from "../../stores/theme.svelte";

	interface Props {
		folder: FolderState;
		onCollapse?: (collapsed: boolean) => void;
		onDelete?: () => void;
		onRename?: () => void;
		onRenameCommit?: (payload: { name: string; color: string }) => void;
		onRenameCancel?: () => void;
		onContextMenu?: (rect: DOMRect) => void;
		isRenaming?: boolean;
		/** Depth in the sidebar tree, 1 at the root. */
		level?: number;
		tabStop?: boolean;
		/** The active tab sits somewhere inside this folder: mark the row so a collapsed folder shows where you are. */
		containsActiveTab?: boolean;
	}

	let {
		folder,
		onCollapse,
		onDelete,
		onRename,
		onRenameCommit,
		onRenameCancel,
		onContextMenu,
		isRenaming = false,
		level = 1,
		tabStop = true,
		containsActiveTab = false,
	}: Props = $props();

	const panel = $derived(getLockPanel()?.folderId === folder.id ? getLockPanel() : null);
	let password = $state("");
	let confirmation = $state("");
	let allowsBiometrics = $state(true);
	let passwordInput: HTMLInputElement | null = $state(null);
	const setupValid = $derived(password.length > 0 && password === confirmation);

	// The panel's job is done once the folder changes state: unlocked, or freshly locked.
	$effect(() => {
		if (panel?.kind === "unlock" && !folder.isLocked) closeLockPanel();
		if (panel?.kind === "setup" && folder.isLocked) closeLockPanel();
	});

	$effect(() => {
		if (panel) {
			password = "";
			confirmation = "";
			queueMicrotask(() => passwordInput?.focus());
		}
	});

	$effect(() => {
		if (panel?.failed) {
			password = "";
			passwordInput?.focus();
		}
	});

	function handleRowActivate(): void {
		if (folder.isLocked) {
			if (panel?.kind === "unlock") closeLockPanel();
			else openLockPanel(folder.id, "unlock");
			return;
		}
		onCollapse?.(!folder.isCollapsed);
	}

	function submitPanel(): void {
		if (panel?.kind === "unlock") {
			if (password) folderActions.unlockWithPassword(folder.id, password);
		} else if (setupValid) {
			folderActions.setLock(folder.id, password, allowsBiometrics && panel?.biometricsAvailable === true);
		}
	}

	function handlePanelKeydown(e: KeyboardEvent): void {
		if (e.key === "Enter") {
			e.preventDefault();
			submitPanel();
		} else if (e.key === "Escape") {
			e.preventDefault();
			closeLockPanel();
		}
	}

	let editInput: HTMLInputElement | null = $state(null);
	let draftName = $state("");
	let draftColor = $state("");
	let wasRenaming = false;

	$effect(() => {
		if (isRenaming && !wasRenaming) {
			draftName = folder.name;
			draftColor = folder.color;
			queueMicrotask(() => {
				editInput?.focus();
				editInput?.select();
			});
		}
		wasRenaming = isRenaming;
	});

	function commitEdit(): void {
		const trimmed = draftName.trim();
		if (!trimmed) {
			onRenameCancel?.();
			return;
		}
		onRenameCommit?.({ name: trimmed, color: draftColor });
	}

	function handleEditKeydown(e: KeyboardEvent): void {
		if (e.key === "Enter") {
			e.preventDefault();
			commitEdit();
		} else if (e.key === "Escape") {
			e.preventDefault();
			onRenameCancel?.();
		}
	}

	function handleEditShellFocusOut(e: FocusEvent): void {
		if (!isRenaming) return;
		if (e.currentTarget instanceof HTMLElement && e.relatedTarget instanceof Node) {
			if (e.currentTarget.contains(e.relatedTarget)) return;
		}
		commitEdit();
	}

	// Turning Touch ID on takes the folder password; turning it off applies at once.
	let enablingBiometrics = $state(false);
	let biometricsPassword = $state("");
	let biometricsRejected = $state(false);
	let biometricsInput: HTMLInputElement | null = $state(null);

	$effect(() => {
		if (!isRenaming || folder.lock?.allowsBiometrics) cancelBiometrics();
	});

	$effect(() =>
		on("folderPasswordRejected", (data) => {
			if (data.id !== folder.id) return;
			biometricsRejected = true;
			biometricsPassword = "";
			biometricsInput?.focus();
		}),
	);

	function handleBiometricsToggle(e: Event): void {
		if ((e.currentTarget as HTMLInputElement).checked) {
			enablingBiometrics = true;
			queueMicrotask(() => biometricsInput?.focus());
		} else if (enablingBiometrics) {
			cancelBiometrics();
		} else {
			folderActions.setBiometrics(folder.id, false);
		}
	}

	function cancelBiometrics(): void {
		enablingBiometrics = false;
		biometricsPassword = "";
		biometricsRejected = false;
	}

	function submitBiometrics(): void {
		if (biometricsPassword) folderActions.setBiometrics(folder.id, true, biometricsPassword);
	}

	function handleBiometricsKeydown(e: KeyboardEvent): void {
		if (e.key === "Enter") {
			e.preventDefault();
			submitBiometrics();
		} else if (e.key === "Escape") {
			e.preventDefault();
			e.stopPropagation();
			cancelBiometrics();
		}
	}

	// The rename editor and the lock panel share the extension: save the edit, then hand over.
	function runLockAction(action: (id: string) => void): void {
		commitEdit();
		action(folder.id);
	}

	function handlePrimaryAction(e: MouseEvent): void {
		e.stopPropagation();
		if (isRenaming) {
			commitEdit();
			return;
		}
		onRename?.();
	}

	function handleContextMenu(e: MouseEvent): void {
		e.preventDefault();
		e.stopPropagation();
		onContextMenu?.((e.currentTarget as HTMLElement).getBoundingClientRect());
	}
</script>

<div
	class="folder-edit-shell"
	class:editing={isRenaming || panel != null}
	style={folderColorStyle(isRenaming ? draftColor || folder.color : folder.color)}
	onfocusout={handleEditShellFocusOut}
>
	<div
		class="folder-row"
		class:collapsed={folder.isCollapsed}
		class:contains-active={containsActiveTab}
		role="treeitem"
		aria-level={level}
		aria-selected={false}
		aria-expanded={!folder.isCollapsed}
		aria-label={folder.isLocked ? `${folder.name}, ${t("tabFolder.locked")}` : folder.name}
		tabindex={tabStop ? 0 : -1}
		onclick={handleRowActivate}
		oncontextmenu={handleContextMenu}
		onkeydown={(e) => {
			// Only keys aimed at the row itself activate it: the rename input and the action
			// buttons live inside, and their keystrokes bubble through here.
			if (e.target !== e.currentTarget) return;
			if (e.key === "Enter" || e.key === " ") {
				e.preventDefault();
				handleRowActivate();
			} else if (!folder.isLocked && (e.key === "ArrowLeft" ? !folder.isCollapsed : e.key === "ArrowRight" && folder.isCollapsed)) {
				// Left on a closed folder is left to the list, which moves up to the parent folder.
				e.preventDefault();
				onCollapse?.(e.key === "ArrowLeft");
			}
		}}
	>
		<div
			class="folder-icon folder-icon-contrast"
			class:folder-icon--open={!folder.isCollapsed}
			aria-hidden="true"
		>
			<svg width="18" height="18" viewBox="0 0 18 18" fill="none">
				<g>
					<g class="folder-back">
						<path
							class="folder-back-fill"
							d="M2.65 6.05C2.65 5.38 3.16 4.88 3.83 4.88H6.7L7.98 6.08H14.16C14.82 6.08 15.32 6.59 15.32 7.25V12.42C15.32 13.09 14.82 13.6 14.16 13.6H3.83C3.16 13.6 2.65 13.09 2.65 12.42V6.05Z"
						/>
					</g>
					<g class="folder-lid">
						<path
							class="folder-lid-fill"
							d="M2.65 6.72C2.65 6.08 3.13 5.6 3.77 5.6H6.7L7.98 4.38C8.18 4.18 8.46 4.08 8.74 4.08H12.18C12.73 4.08 13.16 4.51 13.16 5.06V5.6H14.2C14.84 5.6 15.32 6.08 15.32 6.72V7.88H2.65V6.72Z"
						/>
						<path
							class="folder-icon-outline"
							d="M2.65 6.72C2.65 6.08 3.13 5.6 3.77 5.6H6.7L7.98 4.38C8.18 4.18 8.46 4.08 8.74 4.08H12.18C12.73 4.08 13.16 4.51 13.16 5.06V5.6H14.2C14.84 5.6 15.32 6.08 15.32 6.72V7.18"
						/>
					</g>
					<g class="folder-file">
						<rect class="folder-file-fill" x="4.9" y="4.6" width="3.6" height="3.1" rx="0.7" />
						<rect class="folder-file-fill" x="9.4" y="3.7" width="3.6" height="5" rx="0.7" />
					</g>
					<g class="folder-front">
						<path
							class="folder-front-fill"
							d="M2.65 6.5H15.35V12.42C15.35 13.1 14.84 13.62 14.16 13.62H3.84C3.16 13.62 2.65 13.1 2.65 12.42V6.5Z"
						/>
						<path
							class="folder-icon-outline"
							d="M2.65 6.5H15.35V12.42C15.35 13.1 14.84 13.62 14.16 13.62H3.84C3.16 13.62 2.65 13.1 2.65 12.42V6.5Z"
						/>
					</g>
				</g>
			</svg>
		</div>

		{#if isRenaming}
			<input
				bind:this={editInput}
				bind:value={draftName}
				class="folder-title-input"
				type="text"
				onclick={(e) => e.stopPropagation()}
				onkeydown={handleEditKeydown}
				aria-label={t("tabFolder.folderTitle")}
			/>
		{:else}
			<span class="folder-title">{folder.name}</span>
		{/if}

		{#if folder.isLocked}
			<svg class="lock-icon" width="14" height="14" viewBox="0 0 16 16" fill="none" role="img" aria-label={t("tabFolder.locked")}>
				<rect x="3" y="7" width="10" height="7" rx="1.8" stroke="currentColor" stroke-width="1.4" />
				<path d="M5.5 7V5.2a2.5 2.5 0 0 1 5 0V7" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
			</svg>
		{:else if folder.lock}
			<button class="action-btn relock-btn" aria-label={t("tabFolder.lockNow")} onmousedown={(e) => e.preventDefault()} onclick={(e) => { e.stopPropagation(); folderActions.lock(folder.id); }}>
				<svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true">
					<rect x="3" y="7" width="10" height="7" rx="1.8" stroke="currentColor" stroke-width="1.4" />
					<path d="M5.5 7V5.2a2.5 2.5 0 0 1 4.9-.7" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
				</svg>
			</button>
		{/if}

		<!-- WebKit buttons do not take focus on click: without this, mousedown blurs the
		     rename input with relatedTarget null and the editor commits before the click. -->
		{#if !folder.isLocked}
		<div class="folder-actions">
			<button class="action-btn" aria-label={isRenaming ? t("tabFolder.saveFolder") : t("tabFolder.editFolder")} onmousedown={(e) => e.preventDefault()} onclick={handlePrimaryAction}>
				<!-- Drawn on the tab close icon's 10px grid and 1.5 stroke, so the row's buttons match. -->
				{#if isRenaming}
					<svg width="10" height="10" viewBox="0 0 10 10" fill="none">
						<path d="M1.8 5.2L4 7.4L8.2 2.8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
					</svg>
				{:else}
					<svg width="10" height="10" viewBox="0 0 10 10" fill="none">
						<path d="M6.6 1.9L8.1 3.4L3.4 8.1H1.9V6.6L6.6 1.9Z" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" />
					</svg>
				{/if}
			</button>
			<button class="action-btn delete-btn" aria-label={t("tabFolder.deleteFolder")} onmousedown={(e) => e.preventDefault()} onclick={(e) => { e.stopPropagation(); onDelete?.(); }}>
				<svg width="10" height="10" viewBox="0 0 10 10" fill="none">
					<path d="M1.5 2.6H8.5M4 2.6V1.5H6V2.6M2.7 2.6L3.2 8.5H6.8L7.3 2.6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
				</svg>
			</button>
		</div>
		{/if}
	</div>

	<div class="folder-edit-extension" class:open={isRenaming}>
		<div class="folder-edit-extension-clip">
			{#if isRenaming}
				<div
					class="folder-edit-form"
					role="dialog"
					aria-label={t("tabFolder.editFolder")}
					tabindex="-1"
				>
					<div class="folder-color-grid" role="group" aria-label={t("tabFolder.folderColor")}>
						{#each FOLDER_COLORS as color (color)}
							<button
								class="folder-color-swatch"
								class:selected={draftColor === color}
								style={`--swatch-color: ${color};`}
								aria-label={t("tabFolder.setFolderColor", { color })}
								onmousedown={(e) => e.preventDefault()}
								onclick={() => { draftColor = color; }}
							></button>
						{/each}
					</div>
					{#if folder.lock?.biometricsAvailable}
						<label class="lock-check edit-lock-check">
							<input type="checkbox" checked={folder.lock.allowsBiometrics || enablingBiometrics} onchange={handleBiometricsToggle} />
							{t("tabFolder.allowTouchId")}
						</label>
						{#if enablingBiometrics}
							<div class="lock-field-row edit-lock-field">
								<input bind:this={biometricsInput} bind:value={biometricsPassword} type="password" class="lock-input" placeholder={t("tabFolder.password")} aria-label={t("tabFolder.password")} onkeydown={handleBiometricsKeydown} />
								<button type="button" class="action-btn" aria-label={t("tabFolder.allowTouchId")} onmousedown={(e) => e.preventDefault()} onclick={submitBiometrics}>
									<svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M2.5 6h7M6.5 3l3 3-3 3" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" /></svg>
								</button>
							</div>
							{#if biometricsRejected}<p class="lock-error" role="alert">{t("tabFolder.wrongPassword")}</p>{/if}
						{/if}
					{/if}
					{#if !folder.isSplit}
						<div class="lock-buttons edit-lock-buttons">
							{#if folder.lock}
								<button type="button" class="lock-secondary" onmousedown={(e) => e.preventDefault()} onclick={() => runLockAction(folderActions.changePassword)}>{t("tabFolder.changePassword")}</button>
								<button type="button" class="lock-secondary" onmousedown={(e) => e.preventDefault()} onclick={() => runLockAction(folderActions.removeLock)}>{t("tabFolder.removeLock")}</button>
							{:else}
								<button type="button" class="lock-secondary" onmousedown={(e) => e.preventDefault()} onclick={() => runLockAction(folderActions.beginLockSetup)}>{t("tabFolder.lockFolder")}</button>
							{/if}
						</div>
					{/if}
				</div>
			{/if}
		</div>
	</div>

	<div class="folder-edit-extension" class:open={panel != null}>
		<div class="folder-edit-extension-clip">
			{#if panel}
				<form class="folder-lock-form" onsubmit={(e) => { e.preventDefault(); submitPanel(); }}>
					{#if panel.kind === "unlock"}
						{#if folder.lock?.allowsBiometrics}
							<button type="button" class="lock-primary" onclick={() => folderActions.unlockWith(folder.id, "biometrics")}>{t("tabFolder.unlockTouchId")}</button>
						{/if}
						<div class="lock-field-row">
							<input bind:this={passwordInput} bind:value={password} type="password" class="lock-input" placeholder={t(folder.lock?.allowsBiometrics ? "tabFolder.passwordPlaceholder" : "tabFolder.password")} aria-label={t("tabFolder.password")} onkeydown={handlePanelKeydown} />
							<button type="submit" class="action-btn" aria-label={t("tabFolder.unlock")}>
								<svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M2.5 6h7M6.5 3l3 3-3 3" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" /></svg>
							</button>
						</div>
						{#if panel.failed}<p class="lock-error" role="alert">{t("tabFolder.wrongPassword")}</p>{/if}
						{#if folder.lock?.allowsBiometrics}
							<button type="button" class="lock-link" onclick={() => folderActions.unlockWith(folder.id, "deviceOwner")}>{t("tabFolder.forgotPassword")}</button>
						{:else}
							<button type="button" class="lock-link" onclick={() => folderActions.delete(folder.id)}>{t("tabFolder.deleteWithTabs")}</button>
						{/if}
					{:else}
						<label class="lock-label" for={`lock-pass-${folder.id}`}>{t("tabFolder.password")}</label>
						<input id={`lock-pass-${folder.id}`} bind:this={passwordInput} bind:value={password} type="password" class="lock-input" onkeydown={handlePanelKeydown} />
						<label class="lock-label" for={`lock-confirm-${folder.id}`}>{t("tabFolder.confirmPassword")}</label>
						<input id={`lock-confirm-${folder.id}`} bind:value={confirmation} type="password" class="lock-input" onkeydown={handlePanelKeydown} />
						{#if panel.biometricsAvailable}
							<label class="lock-check"><input type="checkbox" bind:checked={allowsBiometrics} /> {t("tabFolder.allowTouchId")}</label>
						{/if}
						<p class="lock-hint">{t(allowsBiometrics && panel.biometricsAvailable ? "tabFolder.forgotHint" : "tabFolder.noRecoveryHint")}</p>
						<div class="lock-buttons">
							<button type="button" class="lock-secondary" onclick={closeLockPanel}>{t("common.cancel")}</button>
							<button type="submit" class="lock-primary" disabled={!setupValid}>{t("tabFolder.lock")}</button>
						</div>
					{/if}
				</form>
			{/if}
		</div>
	</div>
</div>

<style>
	/* The edit border takes no row height, so a folder spaces like a tab. */
	.folder-edit-shell {
		position: relative;
		margin-block: -1px;
		width: 100%;
		min-width: 0;
		border: 1px solid transparent;
		border-radius: var(--radius-md);
		transition:
			background var(--motion-duration-normal) var(--motion-ease-spring),
			border-color var(--motion-duration-normal) var(--motion-ease-spring),
			box-shadow var(--motion-duration-normal) var(--motion-ease-spring);
	}

	/* No padding here: the row keeps its rest geometry so the icon and buttons stay put. */
	.folder-edit-shell.editing {
		background: color-mix(in srgb, var(--folder-accent) 7%, var(--bg-hover));
		border-color: color-mix(in srgb, var(--folder-accent) 24%, transparent);
		box-shadow:
			inset 0 1px 0 color-mix(in srgb, white 10%, transparent),
			0 7px 16px color-mix(in srgb, var(--folder-accent) 10%, transparent);
	}

	.folder-row {
		display: flex;
		align-items: center;
		gap: 8px;
		width: 100%;
		min-width: 0;
		height: 28px;
		padding: 6px;
		box-sizing: border-box;
		border-radius: var(--radius-md);
		cursor: pointer;
		overflow: hidden;
		position: relative;
		transition:
			background var(--transition-fast),
			box-shadow var(--transition-fast),
			transform 220ms var(--motion-ease-spring);
	}

	/* The tab rows' hover recipe (TabItem), tinted with the folder's color. */
	.folder-row:hover {
		background: color-mix(in srgb, var(--folder-accent) 4%, color-mix(in srgb, var(--bg-selected) 20%, transparent));
	}

	.folder-row:focus-visible {
		outline: var(--focus-outline);
		outline-offset: -2px;
	}

	/* The folder holding the active tab: a faint persistent wash in its own colour, well under the
	   active tab's own fill, so a collapsed folder still shows where you are. */
	.folder-row.contains-active {
		background: color-mix(in srgb, var(--folder-accent) 10%, transparent);
	}

	.folder-row.contains-active:hover {
		background: color-mix(in srgb, var(--folder-accent) 14%, color-mix(in srgb, var(--bg-selected) 20%, transparent));
	}

	.folder-row.contains-active .folder-title {
		color: color-mix(in srgb, var(--text-primary) 82%, var(--folder-accent));
		font-weight: var(--font-weight-medium);
	}

	/* A favicon's 16px box, pulled back over the shell's 1px border: the 18px glyph overflows it
	   evenly, so it centers on the favicon column and the title starts where a tab's does. */
	.folder-icon {
		width: 16px;
		height: 18px;
		margin-left: -1px;
		flex-shrink: 0;
		display: flex;
		align-items: center;
		justify-content: center;
		color: var(--folder-accent);
	}

	.folder-icon svg {
		overflow: visible;
	}

	.folder-icon .folder-back,
	.folder-icon .folder-file,
	.folder-icon .folder-lid,
	.folder-icon .folder-front {
		transform-box: fill-box;
		backface-visibility: hidden;
	}

	.folder-icon .folder-file {
		opacity: 0;
		transform: translateY(1px) scale(0.9);
		transform-origin: 8px 8px;
		transition:
			opacity var(--motion-duration-fast) ease,
			transform 340ms var(--motion-ease-spring);
	}

	.folder-icon .folder-lid {
		transition: opacity var(--motion-duration-normal) ease;
	}

	.folder-icon.folder-icon--open .folder-lid {
		opacity: 0.96;
	}

	.folder-icon.folder-icon--open .folder-back {
		opacity: 0.48;
	}

	.folder-icon.folder-icon--open .folder-file {
		opacity: 1;
		transform: translateY(-2.7px) scale(1);
	}

	.folder-icon-contrast {
		filter: drop-shadow(0 1px 0 color-mix(in srgb, var(--bg-primary) 45%, transparent));
	}

	.folder-back-fill {
		fill: color-mix(in srgb, var(--folder-accent) 42%, var(--bg-hover) 28%);
	}

	.folder-file-fill {
		fill: color-mix(in srgb, white 72%, var(--folder-accent) 28%);
		opacity: 0.9;
	}

	/* Near-white papers vanish on a light sidebar's open-folder tint. */
	@media (prefers-color-scheme: light) {
		.folder-file-fill {
			fill: color-mix(in srgb, white 20%, var(--folder-accent) 80%);
		}
	}

	.folder-lid-fill {
		fill: color-mix(in srgb, var(--folder-accent) 74%, white 18%);
	}

	.folder-front-fill {
		fill: color-mix(in srgb, var(--folder-accent) 86%, var(--text-primary) 10%);
	}

	.folder-icon-outline {
		fill: none;
		stroke: color-mix(in srgb, white 78%, var(--folder-accent) 22%);
		stroke-width: 1.2;
		stroke-linecap: round;
		stroke-linejoin: round;
	}

	.folder-title {
		flex: 1;
		min-width: 0;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		font-size: var(--font-size-md);
		line-height: 1.3;
		color: var(--text-primary);
	}

	.folder-title:hover {
		color: color-mix(in srgb, var(--text-primary) 88%, var(--folder-accent) 12%);
	}

	.folder-title-input {
		flex: 1;
		min-width: 0;
		height: 22px;
		box-sizing: border-box;
		border: 1px solid color-mix(in srgb, var(--folder-accent) 32%, transparent);
		border-radius: var(--radius-sm);
		background: color-mix(in srgb, var(--bg-hover) 88%, transparent);
		color: var(--text-primary);
		font-size: var(--font-size-md);
		line-height: 1.3;
		padding: 0 6px;
		outline: none;
	}

	.folder-title-input:focus {
		border-color: color-mix(in srgb, var(--folder-accent) 68%, var(--text-primary));
		box-shadow: 0 0 0 2px color-mix(in srgb, var(--folder-accent) 18%, transparent);
	}

	/* Collapsed at rest so the lock button sits at the row's right edge. Packed to the end so the
	   buttons hold still while the width opens, instead of riding its left edge. */
	.folder-actions {
		display: flex;
		align-items: center;
		justify-content: flex-end;
		gap: 4px;
		flex-shrink: 0;
		max-width: 0;
		overflow: hidden;
		opacity: 0;
		pointer-events: none;
		transition:
			opacity var(--motion-duration-fast) ease,
			max-width 140ms ease;
	}

	.folder-row:hover .folder-actions,
	.folder-row:focus-visible .folder-actions,
	.folder-actions:focus-within {
		/* Room for two square buttons: squeezed, they turn into pills. */
		max-width: 44px;
		opacity: 1;
		pointer-events: auto;
	}

	/* Base .action-btn recipe is global (styles/utilities.css), and it carries a surface at rest.
	   The row already paints its own, so drop it and only answer the pointer. */
	.action-btn {
		flex-shrink: 0;
		width: 20px;
		height: 20px;
		background: transparent;
		color: var(--text-muted);
	}

	.action-btn:hover {
		background: var(--text-primary-tint-12);
		color: var(--text-primary);
	}

	/* Same specificity as the rule above, so this has to stay after it to win. */
	.delete-btn:hover {
		background: var(--danger);
		color: var(--on-color);
	}

	.folder-edit-extension {
		display: grid;
		grid-template-rows: 0fr;
		opacity: 0;
		transform: translateY(-3px);
		transition:
			grid-template-rows 210ms var(--motion-ease-spring),
			opacity var(--motion-duration-fast) ease,
			transform 210ms var(--motion-ease-spring);
		overflow: hidden;
	}

	.folder-edit-extension.open {
		grid-template-rows: 1fr;
		opacity: 1;
		transform: translateY(0);
	}

	.folder-edit-extension-clip {
		min-height: 0;
		overflow: hidden;
	}

	.folder-edit-form {
		padding: 4px 6px 6px;
	}

	.folder-color-grid {
		display: grid;
		grid-template-columns: repeat(8, 1fr);
		gap: 4px;
		margin-top: 6px;
	}

	.folder-color-swatch {
		width: 20px;
		height: 20px;
		border: 1px solid color-mix(in srgb, black 18%, transparent);
		border-radius: var(--radius-chip);
		background: var(--swatch-color);
		cursor: pointer;
		padding: 0;
		box-shadow: inset 0 1px 0 color-mix(in srgb, white 34%, transparent);
		transition:
			transform 120ms ease,
			box-shadow var(--motion-duration-fast) ease,
			border-color var(--motion-duration-fast) ease;
	}

	.folder-color-swatch:hover {
		transform: scale(1.08);
	}

	.folder-color-swatch.selected {
		border-color: color-mix(in srgb, white 70%, var(--swatch-color));
		box-shadow:
			inset 0 1px 0 color-mix(in srgb, white 34%, transparent),
			0 0 0 2px color-mix(in srgb, var(--swatch-color) 36%, transparent);
	}

	.lock-icon {
		flex-shrink: 0;
		color: var(--text-muted);
	}

	.relock-btn {
		flex-shrink: 0;
		color: var(--text-secondary);
	}

	.folder-lock-form {
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 6px;
	}

	.lock-field-row {
		display: flex;
		align-items: center;
		gap: 6px;
	}

	.lock-input {
		height: 28px;
		box-sizing: border-box;
		padding: 0 10px;
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		background: var(--bg-primary);
		color: var(--text-primary);
		font-size: var(--font-size-md);
		font-family: inherit;
		outline: none;
		transition: border-color var(--transition-fast);
	}

	.lock-field-row .lock-input {
		flex: 1;
		min-width: 0;
	}

	.lock-input::placeholder {
		color: var(--text-muted);
	}

	.lock-input:focus {
		border-color: var(--folder-accent);
	}

	.lock-primary {
		height: 28px;
		padding: 0 14px;
		border: none;
		border-radius: var(--radius-sm);
		background: var(--folder-accent);
		color: var(--accent-text);
		font-size: var(--font-size-sm);
		font-weight: var(--font-weight-semibold);
		font-family: inherit;
		cursor: pointer;
	}

	.lock-primary:disabled {
		opacity: var(--disabled-opacity);
		cursor: default;
	}

	.lock-secondary {
		height: 28px;
		padding: 0 14px;
		border: none;
		border-radius: var(--radius-sm);
		background: var(--text-primary-tint-10);
		color: var(--text-primary);
		font-size: var(--font-size-sm);
		font-family: inherit;
		cursor: pointer;
	}

	.lock-buttons {
		display: flex;
		justify-content: flex-end;
		gap: 6px;
	}

	.edit-lock-buttons {
		flex-direction: column;
		margin-top: 8px;
	}

	.lock-label {
		font-size: var(--font-size-xs);
		font-weight: var(--font-weight-semibold);
		color: var(--text-muted);
		text-transform: uppercase;
		letter-spacing: 0.5px;
	}

	.lock-hint {
		font-size: var(--font-size-xs);
		color: var(--text-secondary);
	}

	.lock-check {
		display: flex;
		align-items: center;
		gap: 6px;
		font-size: var(--font-size-sm);
		color: var(--text-primary);
	}

	.lock-check input {
		accent-color: var(--folder-accent);
	}

	.edit-lock-check {
		margin: 10px 0 6px;
	}

	.edit-lock-field {
		margin-bottom: 4px;
	}

	.lock-error {
		font-size: var(--font-size-xs);
		color: var(--danger-text);
	}

	.lock-link {
		align-self: flex-start;
		border: none;
		background: none;
		padding: 0;
		font-size: var(--font-size-xs);
		font-family: inherit;
		color: var(--text-secondary);
		cursor: pointer;
		text-decoration: underline;
	}

	@media (prefers-reduced-motion: reduce) {
		.folder-icon .folder-file,
		.folder-icon .folder-lid {
			transition: none;
			transform: none;
		}

		.folder-edit-shell,
		.folder-edit-extension {
			transition: none;
			transform: none;
		}
	}
</style>
