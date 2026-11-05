import assert from "node:assert/strict";
import test from "node:test";

import { canSave, initialProfileChoice, spaceEditorSubmission, spaceEditorUpdate } from "./spaceEditorModel";

const users = [
  { id: "perso", isDefault: true },
  { id: "work", isDefault: false },
];
const fields = {
  mode: "add" as const,
  spaceId: "",
  name: "Music",
  icon: "🎧",
  color: "#b39df4",
  colorMode: "time" as const,
  material: "grain" as const,
  profileId: "work",
  archiveAfterHours: 24,
};

test("a new space starts on the preselected user profile", () => {
  assert.deepEqual(initialProfileChoice(fields, false, users), { kind: "profile", id: "work" });
});

test("a new space opened from the Agents space starts on the default user profile", () => {
  assert.deepEqual(
    initialProfileChoice({ ...fields, profileId: "agents" }, false, users),
    { kind: "profile", id: "perso" },
  );
});

test("editing keeps the space's profile, or Private for a private space", () => {
  const edit = { ...fields, mode: "edit" as const, spaceId: "s1", profileId: "work" };
  assert.deepEqual(initialProfileChoice(edit, false, users), { kind: "profile", id: "work" });
  assert.deepEqual(initialProfileChoice(edit, true, users), { kind: "private" });
});

test("canSave needs a name, and a profile name for a new profile", () => {
  assert.equal(canSave("Perso", { kind: "profile", id: "perso" }, ""), true);
  assert.equal(canSave("   ", { kind: "profile", id: "perso" }, ""), false);
  assert.equal(canSave("Music", { kind: "new" }, "  "), false);
  assert.equal(canSave("Music", { kind: "new" }, "Client"), true);
  assert.equal(canSave("Music", { kind: "private" }, ""), true);
});

test("an existing profile goes in the payload as profileId", () => {
  assert.deepEqual(spaceEditorSubmission(fields, { kind: "profile", id: "work" }, { name: "", color: "" }), {
    name: "Music", icon: "🎧", color: "#b39df4", colorMode: "time", material: "grain", profileId: "work",
  });
});

test("a new profile is created with the space, named and colored", () => {
  assert.deepEqual(spaceEditorSubmission(fields, { kind: "new" }, { name: " Client ", color: "#f4bb8c" }), {
    name: "Music", icon: "🎧", color: "#b39df4", colorMode: "time", material: "grain", newProfileName: "Client", newProfileColor: "#f4bb8c",
  });
});

test("Private creates a private space with no profile", () => {
  assert.deepEqual(spaceEditorSubmission(fields, { kind: "private" }, { name: "", color: "" }), {
    name: "Music", icon: "🎧", color: "#b39df4", colorMode: "time", material: "grain", isPrivate: true,
  });
});

test("an edited space gets only what changed, and never a blank name", () => {
  const space = { id: "s1", name: "Music", icon: "🎧", color: "#b39df4", colorMode: "time" as const, material: "grain" as const, archiveAfterHours: 24 };
  const edit = { ...fields, mode: "edit" as const, spaceId: "s1" };
  assert.equal(spaceEditorUpdate(edit, space), null);
  assert.deepEqual(spaceEditorUpdate({ ...edit, color: "#f4bb8c", material: "glass" }, space), { id: "s1", color: "#f4bb8c", material: "glass" });
  assert.equal(spaceEditorUpdate({ ...edit, name: "  " }, space), null);
  assert.deepEqual(spaceEditorUpdate({ ...edit, name: " Band " }, space), { id: "s1", name: "Band" });
});
