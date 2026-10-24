export const MOTION = {
  itemEnterMs: 200,
  itemExitMs: 160,
  // Long enough for the spring's settle; most of the travel is done in the first ~110ms.
  reorderMs: 260,
  selectionMs: 220,
  // Folder-contents expand transition AND the delay before collapsed contents unmount.
  // TabSection injects it as --folder-collapse-duration so CSS and JS can't drift apart.
  folderCollapseMs: 230,
} as const;
