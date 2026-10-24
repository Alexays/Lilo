import type { DesignSystemSectionId } from "../../stores/panels.svelte";

interface DesignSystemSectionModel {
  id: DesignSystemSectionId;
  group: "Core" | "Chrome" | "System";
  title: string;
  description: string;
}

const SECTIONS: DesignSystemSectionModel[] = [
  {
    id: "foundations",
    group: "Core",
    title: "Foundations",
    description: "Tokens, rhythm, radius, typography, and motion rules.",
  },
  {
    id: "layout",
    group: "Core",
    title: "Layout",
    description: "How sidebar panels and content overlays use space.",
  },
  {
    id: "sidebar",
    group: "Chrome",
    title: "Sidebar",
    description: "Navigation rows, tab states, folders, drag states, and empty rows.",
  },
  {
    id: "panels",
    group: "System",
    title: "Panels",
    description: "Panel headers, inset lists, cards, and empty states.",
  },
  {
    id: "controls",
    group: "System",
    title: "Controls",
    description: "Buttons, toggles, badges, selects, and destructive actions.",
  },
  {
    id: "patterns",
    group: "System",
    title: "Patterns",
    description: "Reusable recipes for browser UI workflows.",
  },
];

const GROUPS: DesignSystemSectionModel["group"][] = ["Core", "Chrome", "System"];

/** The sections grouped as the design system's navigation lists them. */
export function buildDesignSystemGroups() {
  return GROUPS.map((label) => ({
    id: label,
    label,
    sections: SECTIONS.filter((section) => section.group === label).map(({ id, title }) => ({ id, label: title })),
  }));
}

export function getDesignSystemSection(id: DesignSystemSectionId): DesignSystemSectionModel {
  return SECTIONS.find((section) => section.id === id) ?? SECTIONS[0];
}
