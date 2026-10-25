// Pure logic for the space editor: the "Signed in as" choice, save validation, the bridge
// payload it sends.

import type { BridgeCommandPayloadMap, SpaceColorMode } from "../../lib/bridge/protocol";

/** A user profile, a profile created with the space, or a private space that forgets everything. */
export type ProfileChoice = { kind: "profile"; id: string } | { kind: "new" } | { kind: "private" };

interface EditorFields {
  mode: "add" | "edit";
  spaceId: string;
  name: string;
  icon: string;
  color: string;
  colorMode: SpaceColorMode;
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

export function spaceEditorSubmission(
  fields: EditorFields,
  choice: ProfileChoice,
  newProfile: { name: string; color: string },
):
  | { action: "createSpace"; payload: BridgeCommandPayloadMap["createSpace"] }
  | { action: "updateSpace"; payload: BridgeCommandPayloadMap["updateSpace"] } {
  const base = { name: fields.name, icon: fields.icon, color: fields.color, colorMode: fields.colorMode };
  const profile =
    choice.kind === "profile"
      ? { profileId: choice.id }
      : choice.kind === "new"
        ? { newProfileName: newProfile.name.trim(), newProfileColor: newProfile.color }
        : {};
  if (fields.mode === "edit") {
    return { action: "updateSpace", payload: { id: fields.spaceId, ...base, ...profile, archiveAfterHours: fields.archiveAfterHours } };
  }
  return {
    action: "createSpace",
    payload: { ...base, ...profile, ...(choice.kind === "private" ? { isPrivate: true } : {}) },
  };
}
