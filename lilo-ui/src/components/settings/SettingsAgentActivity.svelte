<script lang="ts">
  import { getFormatLocale, t } from "../../lib/i18n/state.svelte";
  import { getAgentActionLog, loadAgentActionLog, openAgentActionLog } from "../../stores/agentActionLog.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import { isToggleOn } from "./settingsPanelModel";

  let { title }: { title: string } = $props();

  const enabled = $derived(isToggleOn("agentActionLog", getSetting));
  const clients = $derived(getAgentActionLog());
  const time = $derived(new Intl.DateTimeFormat(getFormatLocale(), { month: "short", day: "numeric", hour: "numeric", minute: "2-digit", second: "2-digit" }));

  // Native reads the tail of the logs only here: as the page opens, when the log is turned on, and on Refresh.
  $effect(() => {
    if (enabled) loadAgentActionLog();
  });

  function when(iso: string): string {
    const date = new Date(iso);
    return Number.isNaN(date.getTime()) ? "" : time.format(date);
  }
</script>

<UiInsetList {title}>
  <div data-setting-id="agentActivity">
    <UiListRow title={t("settings.items.agentActivity.title")} description={t("settings.items.agentActivity.description")}>
      {#snippet action()}
        {#if enabled}<UiButton onclick={loadAgentActionLog}>{t("settings.agentActivity.refresh")}</UiButton>{/if}
        <UiButton onclick={openAgentActionLog}>{t("settings.agentActivity.open")}</UiButton>
      {/snippet}
    </UiListRow>
  </div>
  {#if !enabled}
    <UiListRow title={t("settings.agentActivity.off")} description={t("settings.agentActivity.offDescription")}>
      {#snippet action()}
        <UiButton variant="primary" onclick={() => setSetting("agentActionLog", "true")}>{t("settings.agentActivity.turnOn")}</UiButton>
      {/snippet}
    </UiListRow>
  {:else if clients && !clients.length}
    <p class="empty">{t("settings.agentActivity.empty")}</p>
  {:else if clients}
    {#each clients as client (client.name)}
      <div class="client" role="group" aria-label={client.name}>
        <h4>{client.name}</h4>
        <ol>
          {#each client.calls as call (call.time + call.tool)}
            <li class:failed={!call.ok}>
              <time datetime={call.time}>{when(call.time)}</time>
              <span class="tool">{call.tool}</span>
              <span class="host">{call.host ?? ""}</span>
              {#if !call.ok}<span class="badge" title={call.code ?? ""}>{t("settings.agentActivity.failed")}</span>{/if}
            </li>
          {/each}
        </ol>
      </div>
    {/each}
  {/if}
</UiInsetList>

<style>
  .empty {
    margin: 0;
    padding: 14px;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .client {
    display: grid;
    gap: var(--space-6);
    padding: 11px 14px;
  }

  h4 {
    margin: 0;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  ol {
    display: grid;
    margin: 0;
    padding: 0;
    list-style: none;
    font-size: var(--font-size-sm);
  }

  li {
    display: grid;
    grid-template-columns: minmax(110px, auto) minmax(0, 1fr) minmax(0, 1fr) auto;
    align-items: baseline;
    gap: var(--space-12);
    padding: 3px 0;
    color: var(--text-secondary);
  }

  time {
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }

  .tool {
    overflow: hidden;
    color: var(--text-primary);
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .host {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .badge {
    color: var(--danger-text);
    font-weight: var(--font-weight-medium);
  }
</style>
