<script lang="ts">
	import { t } from "../../lib/i18n/state.svelte";

	let {
		active = false,
		targetName = null,
		accentColor = null,
	}: {
		active?: boolean;
		targetName?: string | null;
		accentColor?: string | null;
	} = $props();

	const hintStyle = $derived(
		accentColor ? `--space-move-hint-accent: ${accentColor};` : "",
	);
</script>

{#if active}
	<div class="space-move-hint" style={hintStyle} aria-hidden="true">
		<span class="space-move-hint-dot"></span>
		{#if targetName}
			<span>{t("spaceMoveHint.moveTo", { name: targetName })}</span>
		{:else}
			<span>{t("spaceMoveHint.moveToAnotherSpace")}</span>
		{/if}
	</div>
{/if}

<style>
	.space-move-hint {
		position: absolute;
		left: 50%;
		bottom: calc(100% + 8px);
		z-index: 28;
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		height: 28px;
		width: max-content;
		min-width: min(150px, calc(100% - 16px));
		max-width: calc(100% - 16px);
		box-sizing: border-box;
		padding: 0 10px;
		border: 1px solid color-mix(in srgb, var(--space-move-hint-accent) 22%, transparent);
		border-radius: var(--radius-md);
		background: color-mix(in srgb, var(--bg-primary) 86%, transparent);
		color: var(--text-secondary);
		box-shadow: 0 10px 22px var(--text-primary-tint-10);
		font-size: var(--font-size-sm);
		white-space: nowrap;
		pointer-events: none;
		backdrop-filter: blur(var(--chrome-floating-blur));
		transform: translateX(-50%);
		transform-origin: 50% calc(100% + 8px);
		animation: space-move-hint-in 320ms var(--motion-ease-bounce);
		--space-move-hint-accent: var(--accent);
	}

	.space-move-hint::after {
		content: "";
		position: absolute;
		left: 50%;
		bottom: -5px;
		width: 9px;
		height: 9px;
		background: inherit;
		border-right: 1px solid color-mix(in srgb, var(--space-move-hint-accent) 22%, transparent);
		border-bottom: 1px solid color-mix(in srgb, var(--space-move-hint-accent) 22%, transparent);
		transform: translateX(-50%) rotate(45deg);
	}

	.space-move-hint > span:last-child {
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.space-move-hint-dot {
		width: 6px;
		height: 6px;
		border-radius: var(--radius-chip);
		background: var(--space-move-hint-accent);
		box-shadow: 0 0 0 4px color-mix(in srgb, var(--space-move-hint-accent) 16%, transparent);
	}

	@keyframes space-move-hint-in {
		from {
			opacity: 0;
			transform: translateX(-50%) translateY(7px) scale(0.94);
		}

		to {
			opacity: 1;
			transform: translateX(-50%) translateY(0) scale(1);
		}
	}
</style>
