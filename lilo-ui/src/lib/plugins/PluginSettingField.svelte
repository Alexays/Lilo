<script lang="ts">
  import UiSelect from "../../components/ui/UiSelect.svelte";
  import UiTextField from "../../components/ui/UiTextField.svelte";
  import UiToggle from "../../components/ui/UiToggle.svelte";
  import { t } from "../i18n/state.svelte";
  import { parseSettingInput, type PluginSettingSpec, type PluginSettingValue } from "./pluginModel";

  interface Props {
    spec: PluginSettingSpec;
    value: PluginSettingValue;
    /** Called with the value to store: on each switch or choice, on Enter or blur for a typed one. */
    oncommit: (value: PluginSettingValue) => void;
  }

  let { spec, value, oncommit }: Props = $props();

  function commitText(input: string): void {
    const parsed = parseSettingInput(spec, input);
    if (parsed !== null && parsed !== value) oncommit(parsed);
  }
</script>

{#if spec.type === "toggle"}
  <UiToggle checked={value === true} ariaLabel={spec.title} onchange={oncommit} />
{:else if spec.type === "dropdown"}
  <UiSelect
    value={String(value)}
    options={(spec.options ?? []).map((option) => ({ value: option, label: option }))}
    ariaLabel={spec.title}
    onchange={oncommit}
  />
{:else}
  <span class="plugin-field">
    <UiTextField
      type={spec.type === "password" ? "password" : "text"}
      value={String(value)}
      ariaLabel={spec.title}
      placeholder={spec.required ? t("plugins.required") : ""}
      oncommit={commitText}
    />
  </span>
{/if}

<style>
  .plugin-field {
    display: block;
    width: 200px;
    max-width: 100%;
  }
</style>
