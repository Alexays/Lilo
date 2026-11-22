<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import type { AgentCommand } from "../../lib/agentCommands";
  import SettingsCustomAgent from "./SettingsCustomAgent.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiModal from "../ui/UiModal.svelte";

  interface Props {
    /** The command being edited; absent, the sheet adds one. */
    editing?: AgentCommand;
    onsave: (command: AgentCommand) => void;
    oncancel: () => void;
  }

  let { editing, onsave, oncancel }: Props = $props();

  let values = $state({
    name: editing?.name ?? "",
    executable: editing?.executable ?? "",
    arguments: editing?.arguments ?? "",
    environment: editing?.environment ?? "",
  });

  function save(): void {
    if (!values.executable.trim()) return;
    onsave({
      id: editing?.id ?? `command-${crypto.randomUUID()}`,
      name: values.name.trim(),
      executable: values.executable.trim(),
      arguments: values.arguments,
      environment: values.environment,
    });
  }
</script>

<UiModal zone="add-agent" width={560} scrolls title={editing ? t("settings.agentSheet.editTitle") : t("settings.agentSheet.addTitle")} {oncancel} ondefault={save}>
  <SettingsCustomAgent bind:values />

  {#snippet actions()}
    <UiButton onclick={oncancel}>{t("common.cancel")}</UiButton>
    <UiButton variant="primary" disabled={!values.executable.trim()} onclick={save}>
      {editing ? t("common.save") : t("settings.agentSheet.add")}
    </UiButton>
  {/snippet}
</UiModal>
