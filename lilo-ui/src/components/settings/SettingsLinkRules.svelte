<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getAgentsSpaceId } from "../../stores/agents.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import { getSpaces } from "../../stores/spaces.svelte";
  import { type LinkRule, parseLinkRules } from "./settingsPanelModel";
  import UiButton from "../ui/UiButton.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiSelect from "../ui/UiSelect.svelte";
  import UiTextField from "../ui/UiTextField.svelte";

  let { title, description }: { title: string; description: string } = $props();

  const rules = $derived(parseLinkRules(getSetting("externalLinkRules", "")));
  const matchOptions = $derived([
    { value: "host", label: t("settings.linkRules.hostIs") },
    { value: "contains", label: t("settings.linkRules.urlContains") },
  ]);
  const destinations = $derived([
    { value: "little", label: t("settings.linkRules.littleWindow") },
    ...getSpaces()
      .filter((space) => !space.isPrivate && space.id !== getAgentsSpaceId())
      .map((space) => ({ value: space.id, label: `${space.icon} ${space.name}` })),
  ]);

  // The rule being added, saved once it has a pattern; and the row whose pattern was emptied.
  let draft = $state<LinkRule | null>(null);
  let emptyRow = $state<number | "draft" | null>(null);

  function save(next: LinkRule[]): void {
    setSetting("externalLinkRules", JSON.stringify(next));
  }

  function update(index: number, change: Partial<LinkRule>): void {
    const rule = { ...rules[index], ...change };
    rule.pattern = rule.pattern.trim();
    if (!rule.pattern) {
      emptyRow = index;
      return;
    }
    emptyRow = null;
    save(rules.map((existing, position) => (position === index ? rule : existing)));
  }

  function move(index: number, offset: number): void {
    const next = [...rules];
    const [rule] = next.splice(index, 1);
    next.splice(index + offset, 0, rule);
    save(next);
  }

  function remove(index: number): void {
    if (emptyRow === index) emptyRow = null;
    save(rules.filter((_, position) => position !== index));
  }

  function addDraft(): void {
    if (!draft) return;
    const pattern = draft.pattern.trim();
    if (!pattern) {
      emptyRow = "draft";
      return;
    }
    save([...rules, { ...draft, pattern }]);
    draft = null;
    emptyRow = null;
  }
</script>

<UiListRow {title} {description}>
  {#snippet action()}
    <UiButton
      disabled={draft !== null}
      onclick={() => (draft = { match: "host", pattern: "", destination: destinations[0]?.value ?? "little" })}
    >
      {t("settings.linkRules.add")}
    </UiButton>
  {/snippet}
</UiListRow>

{#each rules as rule, index (index)}
  <div class="rule" data-rule-index={index}>
    <UiSelect value={rule.match} options={matchOptions} ariaLabel={t("settings.linkRules.match")} onchange={(value) => update(index, { match: value as LinkRule["match"] })} />
    <UiTextField
      value={rule.pattern}
      placeholder={t(rule.match === "host" ? "settings.linkRules.hostPlaceholder" : "settings.linkRules.containsPlaceholder")}
      ariaLabel={t("settings.linkRules.pattern")}
      oncommit={(value) => update(index, { pattern: value })}
    />
    <UiSelect
      value={rule.destination}
      options={destinations.some((option) => option.value === rule.destination)
        ? destinations
        : [{ value: rule.destination, label: t("settings.linkRules.deletedSpace") }, ...destinations]}
      ariaLabel={t("settings.linkRules.destination")}
      onchange={(value) => update(index, { destination: value })}
    />
    <span class="rule-actions">
      <UiButton variant="ghost" disabled={index === 0} onclick={() => move(index, -1)}>
        <svg viewBox="0 0 12 12" role="img" aria-label={t("settings.linkRules.moveUp")}><path d="m3 7.5 3-3 3 3" /></svg>
      </UiButton>
      <UiButton variant="ghost" disabled={index === rules.length - 1} onclick={() => move(index, 1)}>
        <svg viewBox="0 0 12 12" role="img" aria-label={t("settings.linkRules.moveDown")}><path d="m3 4.5 3 3 3-3" /></svg>
      </UiButton>
      <UiButton variant="ghost" onclick={() => remove(index)}>
        <svg viewBox="0 0 12 12" role="img" aria-label={t("settings.linkRules.delete")}><path d="m3.5 3.5 5 5M8.5 3.5l-5 5" /></svg>
      </UiButton>
    </span>
    {#if emptyRow === index}<p class="rule-error">{t("settings.linkRules.emptyPattern")}</p>{/if}
  </div>
{/each}

{#if draft}
  <div class="rule" data-rule-index="draft">
    <UiSelect
      value={draft.match}
      options={matchOptions}
      ariaLabel={t("settings.linkRules.match")}
      onchange={(value) => {
        if (draft) draft.match = value as LinkRule["match"];
      }}
    />
    <UiTextField
      value={draft.pattern}
      placeholder={t(draft.match === "host" ? "settings.linkRules.hostPlaceholder" : "settings.linkRules.containsPlaceholder")}
      ariaLabel={t("settings.linkRules.pattern")}
      onchange={(value) => {
        if (draft) draft.pattern = value;
      }}
    />
    <UiSelect
      value={draft.destination}
      options={destinations}
      ariaLabel={t("settings.linkRules.destination")}
      onchange={(value) => {
        if (draft) draft.destination = value;
      }}
    />
    <span class="rule-actions">
      <UiButton variant="primary" onclick={addDraft}>{t("settings.linkRules.save")}</UiButton>
      <UiButton
        variant="ghost"
        onclick={() => {
          draft = null;
          emptyRow = null;
        }}
      >
        {t("settings.linkRules.cancel")}
      </UiButton>
    </span>
    {#if emptyRow === "draft"}<p class="rule-error">{t("settings.linkRules.emptyPattern")}</p>{/if}
  </div>
{/if}

<style>
  /* Wraps field by field on a narrow window rather than squeezing each one past its text. */
  .rule {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    align-items: center;
    padding: 6px 0;
  }

  .rule > :global(.ui-select) {
    flex: 1 1 140px;
  }

  .rule > :global(.ui-text-field) {
    flex: 1.4 1 180px;
  }

  .rule-actions {
    display: flex;
    gap: 2px;
    margin-left: auto;
  }

  .rule-actions svg {
    width: 12px;
    height: 12px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.5;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .rule-error {
    flex-basis: 100%;
    margin: 0;
    color: var(--danger-text);
    font-size: var(--font-size-sm);
  }
</style>
