<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { settingsActions } from "../../lib/bridge/actions";
  import SectionNavPanel from "../ui/SectionNavPanel.svelte";
  import {
    closePageShell,
    getDiagnosticsSection,
    isDiagnosticsVisible,
    setDiagnosticsSection,
    type DiagnosticsSectionId,
  } from "../../stores/panels.svelte";
  import { getExtensionDiagnostics, getRecordingStartedAt, loadDiagnostics } from "../../stores/diagnostics.svelte";

  let { compact = false }: { compact?: boolean } = $props();

  const recordingStartedAt = $derived(getRecordingStartedAt());
  let now = $state(Date.now());

  // The elapsed time ticks only while a recording runs and the screen shows it.
  $effect(() => {
    if (recordingStartedAt == null || !isDiagnosticsVisible()) return;
    now = Date.now();
    const timer = setInterval(() => (now = Date.now()), 1000);
    return () => clearInterval(timer);
  });

  const elapsed = $derived.by(() => {
    if (recordingStartedAt == null) return "";
    const seconds = Math.max(0, Math.floor((now - recordingStartedAt) / 1000));
    return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
  });

  const errorCount = $derived(getExtensionDiagnostics().reduce((count, entry) => count + Number(entry.level === "error"), 0));

  const groups = $derived([
    {
      id: "views",
      sections: [
        { id: "startup", label: t("diagnostics.tabStartup"), icon: "stopwatch" as const },
        { id: "memory", label: t("diagnostics.tabMemory"), icon: "chip" as const },
        { id: "log", label: t("diagnostics.tabLog"), icon: "list" as const, count: errorCount },
      ],
    },
    {
      id: "actions",
      sections: [
        {
          id: "record",
          label: recordingStartedAt == null ? t("diagnostics.recordSession") : t("diagnostics.stopRecording"),
          icon: "record" as const,
          count: elapsed,
        },
        { id: "copy", label: t("diagnostics.copyReport"), icon: "copy" as const },
        { id: "refresh", label: t("diagnostics.refresh"), icon: "refresh" as const },
      ],
    },
  ]);

  function select(id: string): void {
    if (id === "record") settingsActions.togglePerfRecording();
    else if (id === "copy") settingsActions.copyDiagnosticsReport();
    else if (id === "refresh") loadDiagnostics();
    else setDiagnosticsSection(id as DiagnosticsSectionId);
  }
</script>

<SectionNavPanel
  title={t("diagnostics.title")}
  ariaLabel={t("diagnostics.tabsAriaLabel")}
  {groups}
  activeId={getDiagnosticsSection()}
  onSelect={select}
  onclose={closePageShell}
  {compact}
/>
