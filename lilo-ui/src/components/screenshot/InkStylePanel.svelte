<script lang="ts">
	import { INK_COLORS, type Dash, type Fill, type Heads, type InkStyle } from "../../lib/ink";
	import { t } from "../../lib/i18n/state.svelte";
	import { tooltip } from "../../lib/tooltip";

	interface Props {
		value: InkStyle;
		/** Thin, bold and extra bold, in the surface's own units. */
		widths: [number, number, number];
		/** Which rows apply to what is drawn or selected. */
		rows: { fill: boolean; heads: boolean; dash: boolean; layers?: boolean; eraser?: boolean };
		erasing?: boolean;
		onChange: (patch: Partial<InkStyle>) => void;
		onLayer?: (to: "front" | "back") => void;
		onEraser?: () => void;
	}

	let { value, widths, rows, erasing = false, onChange, onLayer, onEraser }: Props = $props();

	const WIDTH_NAMES = ["thin", "bold", "extraBold"];
	const FILLS: Fill[] = ["none", "tint", "solid"];
	const DASHES: Dash[] = ["solid", "dashed", "dotted"];
	const HEADS: Heads[] = ["none", "end", "both"];
	const isCustomColor = $derived(!INK_COLORS.some((color) => color.value === value.color));
</script>

<div class="ink-style" role="toolbar" aria-label={t("ink.label")} tabindex="-1">
	<section>
		<h3>{t("ink.stroke")}</h3>
		<div class="row">
			{#each INK_COLORS as color (color.value)}
				<button
					type="button"
					class="swatch"
					class:on={!erasing && value.color === color.value}
					style={`--swatch: ${color.value}`}
					aria-label={t(`ink.colors.${color.name}`)}
					aria-pressed={!erasing && value.color === color.value}
					use:tooltip={t(`ink.colors.${color.name}`)}
					onclick={() => onChange({ color: color.value })}
				></button>
			{/each}
			<label class="swatch custom" class:on={!erasing && isCustomColor} style={isCustomColor ? `--swatch: ${value.color}` : ""} use:tooltip={t("ink.customColor")}>
				{#if !isCustomColor}
					<svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true"><path d="M6 2.5V9.5M2.5 6H9.5" /></svg>
				{/if}
				<input type="color" aria-label={t("ink.customColor")} value={value.color} oninput={(e) => onChange({ color: (e.currentTarget as HTMLInputElement).value })} />
			</label>
		</div>
	</section>

	{#if rows.fill}
		<section>
			<h3>{t("ink.fill")}</h3>
			<div class="row">
				{#each FILLS as fill (fill)}
					<button
						type="button"
						class="option"
						class:on={value.fill === fill}
						aria-label={t(`ink.fills.${fill}`)}
						aria-pressed={value.fill === fill}
						use:tooltip={t(`ink.fills.${fill}`)}
						onclick={() => onChange({ fill })}
					>
						<svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
							<rect x="3" y="3" width="12" height="12" rx="3" stroke="currentColor" stroke-width="1.5"
								fill={fill === "none" ? "none" : "currentColor"} fill-opacity={fill === "tint" ? 0.3 : 1} />
						</svg>
					</button>
				{/each}
			</div>
		</section>
	{/if}

	<section>
		<h3>{t("ink.width")}</h3>
		<div class="row">
			{#each widths as width, index (index)}
				<button
					type="button"
					class="option"
					class:on={!erasing && value.width === width}
					aria-label={t(`ink.widths.${WIDTH_NAMES[index]}`)}
					aria-pressed={!erasing && value.width === width}
					use:tooltip={t(`ink.widths.${WIDTH_NAMES[index]}`)}
					onclick={() => onChange({ width })}
				>
					<svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
						<path d="M3 9h12" stroke="currentColor" stroke-width={1.4 + index * 1.6} stroke-linecap="round" />
					</svg>
				</button>
			{/each}
		</div>
	</section>

	{#if rows.dash}
		<section>
			<h3>{t("ink.dash")}</h3>
			<div class="row">
				{#each DASHES as dash (dash)}
					<button
						type="button"
						class="option"
						class:on={value.dash === dash}
						aria-label={t(`ink.dashes.${dash}`)}
						aria-pressed={value.dash === dash}
						use:tooltip={t(`ink.dashes.${dash}`)}
						onclick={() => onChange({ dash })}
					>
						<svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
							<path d="M3 9h12" stroke="currentColor" stroke-width="2" stroke-linecap="round"
								stroke-dasharray={dash === "dashed" ? "4 3" : dash === "dotted" ? "0 4" : undefined} />
						</svg>
					</button>
				{/each}
			</div>
		</section>
	{/if}

	{#if rows.heads}
		<section>
			<h3>{t("ink.heads")}</h3>
			<div class="row">
				{#each HEADS as heads (heads)}
					<button
						type="button"
						class="option"
						class:on={value.heads === heads}
						aria-label={t(`ink.headKinds.${heads}`)}
						aria-pressed={value.heads === heads}
						use:tooltip={t(`ink.headKinds.${heads}`)}
						onclick={() => onChange({ heads })}
					>
						<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
							<path d="M3 9h12" />
							{#if heads !== "none"}<path d="M11.5 5.5L15 9l-3.5 3.5" />{/if}
							{#if heads === "both"}<path d="M6.5 5.5L3 9l3.5 3.5" />{/if}
						</svg>
					</button>
				{/each}
			</div>
		</section>
	{/if}

	{#if rows.layers && onLayer}
		<section>
			<h3>{t("ink.layers")}</h3>
			<div class="row">
				<button type="button" class="option" aria-label={t("ink.toBack")} use:tooltip={t("ink.toBack")} onclick={() => onLayer("back")}>
					<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" aria-hidden="true">
						<rect x="6.5" y="6.5" width="8.5" height="8.5" rx="2" fill="currentColor" fill-opacity="0.3" />
						<rect x="3" y="3" width="8.5" height="8.5" rx="2" />
					</svg>
				</button>
				<button type="button" class="option" aria-label={t("ink.toFront")} use:tooltip={t("ink.toFront")} onclick={() => onLayer("front")}>
					<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" aria-hidden="true">
						<rect x="3" y="3" width="8.5" height="8.5" rx="2" />
						<rect x="6.5" y="6.5" width="8.5" height="8.5" rx="2" fill="currentColor" fill-opacity="0.3" />
					</svg>
				</button>
			</div>
		</section>
	{/if}

	{#if rows.eraser && onEraser}
		<button type="button" class="eraser" class:on={erasing} aria-pressed={erasing} onclick={onEraser}>{t("ink.eraser")}</button>
	{/if}
</div>

<style>
	/* Takes the colors of where it sits. */
	.ink-style {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	section {
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	h3 {
		margin: 0;
		font-size: var(--font-size-xs);
		font-weight: var(--font-weight-semibold);
		color: inherit;
	}

	.row {
		display: flex;
		flex-wrap: wrap;
		gap: 4px;
	}

	button,
	.swatch.custom {
		width: 28px;
		height: 28px;
		padding: 0;
		border: 0;
		border-radius: var(--radius-sm);
		display: flex;
		align-items: center;
		justify-content: center;
		background: color-mix(in srgb, currentColor 7%, transparent);
		color: inherit;
		cursor: pointer;
	}

	button:hover,
	.swatch.custom:hover {
		background: color-mix(in srgb, currentColor 15%, transparent);
	}

	button.on,
	.swatch.custom.on {
		background: color-mix(in srgb, var(--accent) 34%, transparent);
		box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--accent) 80%, transparent);
	}

	button:focus-visible,
	.swatch.custom:focus-within {
		outline: var(--focus-outline);
	}

	.swatch::before {
		content: "";
		width: 16px;
		height: 16px;
		border-radius: 50%;
		background: var(--swatch);
		box-shadow: inset 0 0 0 1px color-mix(in srgb, currentColor 35%, transparent);
	}

	.swatch.custom {
		position: relative;
		overflow: hidden;
	}

	.swatch.custom:not(.on)::before {
		display: none;
	}

	.swatch.custom input {
		position: absolute;
		inset: 0;
		opacity: 0;
		cursor: pointer;
		border: 0;
		padding: 0;
	}

	.eraser {
		width: auto;
		padding: 0 10px;
		font: inherit;
		font-size: var(--font-size-sm);
	}
</style>
