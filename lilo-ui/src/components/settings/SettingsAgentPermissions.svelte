<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import UiChip from "../ui/UiChip.svelte";
  import UiSegmented from "../ui/UiSegmented.svelte";
  import UiTextField from "../ui/UiTextField.svelte";
  import { DEFAULT_AGENT_PERMISSION, normalizeSite, parseAgentPermissions, setAgentPermission } from "./agentPermissions";

  // What one agent may do on pages without asking: its default, and the sites it alone acts on unasked.
  let { name, title }: { name: string; title: string } = $props();

  const KEY = "agentClientPermissions";
  const permission = $derived(parseAgentPermissions(getSetting(KEY, ""))[name] ?? DEFAULT_AGENT_PERMISSION);
  const asking = $derived(getSetting("agentAskBeforeActions", "true") === "true");
  // Remounts the field after an add: the field keeps what was typed.
  let added = $state(0);

  function save(next: typeof permission): void {
    setSetting(KEY, setAgentPermission(getSetting(KEY, ""), name, next));
  }

  function addSite(value: string): void {
    const site = normalizeSite(value);
    if (!site) return;
    added++;
    if (!permission.sites.includes(site)) save({ ...permission, sites: [...permission.sites, site] });
  }
</script>

<div class="permissions" role="group" aria-label={t("settings.agents.permissions.group", { client: title })}>
  <div class="row">
    <span class="copy">
      <span class="label">{t("settings.agents.permissions.act")}</span>
      <span class="hint">{asking ? t("settings.agents.permissions.actHint") : t("settings.agents.permissions.askingOff")}</span>
    </span>
    <UiSegmented
      value={permission.act}
      ariaLabel={t("settings.agents.permissions.act")}
      options={[
        { value: "ask", label: t("settings.agents.permissions.ask") },
        { value: "always", label: t("settings.agents.permissions.always") },
      ]}
      onchange={(value) => save({ ...permission, act: value === "always" ? "always" : "ask" })}
    />
  </div>
  <div class="row">
    <span class="copy">
      <span class="label">{t("settings.agents.permissions.sites")}</span>
      <span class="chips">
        {#each permission.sites as site (site)}
          <UiChip
            label={site}
            removeLabel={t("settings.agents.permissions.removeSite", { site })}
            onremove={() => save({ ...permission, sites: permission.sites.filter((entry) => entry !== site) })}
          />
        {/each}
      </span>
    </span>
    <span class="add">
      {#key added}
        <UiTextField
          placeholder={t("settings.agents.permissions.addSite")}
          ariaLabel={t("settings.agents.permissions.addSiteLabel", { client: title })}
          oncommit={addSite}
        />
      {/key}
    </span>
  </div>
  <p class="floor">{t("settings.agents.permissions.floor")}</p>
</div>

<style>
  .permissions {
    display: grid;
    gap: var(--space-12);
    padding: var(--space-12) 14px;
    border-radius: var(--radius-box);
    background: var(--group-box-bg);
    box-shadow: inset 0 0 0 1px var(--separator);
  }

  .row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-16);
  }

  .copy {
    display: grid;
    gap: var(--space-4);
    min-width: 0;
  }

  .label {
    font-size: var(--font-size-md);
  }

  .hint,
  .floor {
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .floor {
    margin: 0;
  }

  .chips {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-6);
  }

  .add {
    flex: none;
    width: 200px;
  }
</style>
