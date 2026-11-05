// Pure logic for the space editor: the "Signed in as" choice, validation, the bridge payloads it sends.

import type { BridgeCommandPayloadMap, SpaceColorMode, SpaceMaterial } from "../../lib/bridge/protocol";

/** A user profile, a profile created with the space, or a private space that forgets everything. */
export type ProfileChoice = { kind: "profile"; id: string } | { kind: "new" } | { kind: "private" };

interface EditorFields {
  mode: "add" | "edit";
  spaceId: string;
  name: string;
  icon: string;
  color: string;
  colorMode: SpaceColorMode;
  material: SpaceMaterial;
  profileId: string;
  archiveAfterHours: number;
}

/** The space's own profile when editing; for a new space the preselected one when it is the
 * user's (not the agents' throwaway one), else the default user profile. */
export function initialProfileChoice(
  fields: EditorFields,
  isPrivateSpace: boolean,
  users: { id: string; isDefault: boolean }[],
): ProfileChoice {
  if (isPrivateSpace) return { kind: "private" };
  if (fields.mode === "edit" || users.some((profile) => profile.id === fields.profileId)) {
    return { kind: "profile", id: fields.profileId };
  }
  const fallback = users.find((profile) => profile.isDefault) ?? users[0];
  return { kind: "profile", id: fallback?.id ?? "" };
}

export function canSave(name: string, choice: ProfileChoice, newProfileName: string): boolean {
  return name.trim().length > 0 && (choice.kind !== "new" || newProfileName.trim().length > 0);
}

/** The payload that creates the Space. */
export function spaceEditorSubmission(
  fields: EditorFields,
  choice: ProfileChoice,
  newProfile: { name: string; color: string },
): BridgeCommandPayloadMap["createSpace"] {
  const profile =
    choice.kind === "profile"
      ? { profileId: choice.id }
      : choice.kind === "new"
        ? { newProfileName: newProfile.name.trim(), newProfileColor: newProfile.color }
        : { isPrivate: true };
  return { name: fields.name, icon: fields.icon, color: fields.color, colorMode: fields.colorMode, material: fields.material, ...profile };
}

/** What the editor changed on a Space it edits, or null when nothing; a name is kept until it is not blank. */
export function spaceEditorUpdate(
  fields: EditorFields,
  space: { id: string; name: string; icon: string; color: string; colorMode?: SpaceColorMode; material?: SpaceMaterial; archiveAfterHours?: number },
): BridgeCommandPayloadMap["updateSpace"] | null {
  const update: BridgeCommandPayloadMap["updateSpace"] = { id: space.id };
  const name = fields.name.trim();
  if (name && name !== space.name) update.name = name;
  if (fields.icon !== space.icon) update.icon = fields.icon;
  if (fields.color !== space.color) update.color = fields.color;
  if (fields.colorMode !== (space.colorMode ?? "fixed")) update.colorMode = fields.colorMode;
  if (fields.material !== (space.material ?? "solid")) update.material = fields.material;
  if (fields.archiveAfterHours !== (space.archiveAfterHours ?? 12)) update.archiveAfterHours = fields.archiveAfterHours;
  return Object.keys(update).length > 1 ? update : null;
}
