<script lang="ts">
  import SectionNavPanel from "../ui/SectionNavPanel.svelte";
  import {
    closeDesignSystemShell,
    getDesignSystemShellSection,
    setActiveDesignSystemSection,
  } from "../../stores/panels.svelte";
  import { buildDesignSystemGroups } from "./designSystemModel";

  const activeSection = $derived(getDesignSystemShellSection());
  const sectionGroups = buildDesignSystemGroups();
</script>

<SectionNavPanel
  title="Design System"
  ariaLabel="Design system sections"
  groups={sectionGroups}
  activeId={activeSection}
  onSelect={setActiveDesignSystemSection}
  onclose={closeDesignSystemShell}
/>
