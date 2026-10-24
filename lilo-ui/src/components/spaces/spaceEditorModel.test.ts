import assert from "node:assert/strict";
import test from "node:test";

import { canSave, initialProfileChoice, spaceEditorSubmission } from "./spaceEditorModel";

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
    action: "createSpace",
    payload: { name: "Music", icon: "🎧", color: "#b39df4", profileId: "work" },
  });
});

test("a new profile is created with the space, named and colored", () => {
  assert.deepEqual(spaceEditorSubmission(fields, { kind: "new" }, { name: " Client ", color: "#f4bb8c" }), {
    action: "createSpace",
    payload: { name: "Music", icon: "🎧", color: "#b39df4", newProfileName: "Client", newProfileColor: "#f4bb8c" },
  });
  const edit = { ...fields, mode: "edit" as const, spaceId: "s1" };
  assert.deepEqual(spaceEditorSubmission(edit, { kind: "new" }, { name: "Client", color: "#f4bb8c" }), {
    action: "updateSpace",
    payload: {
      id: "s1",
      name: "Music",
      icon: "🎧",
      color: "#b39df4",
      newProfileName: "Client",
      newProfileColor: "#f4bb8c",
      archiveAfterHours: 24,
    },
  });
});

test("Private creates a private space with no profile", () => {
  assert.deepEqual(spaceEditorSubmission(fields, { kind: "private" }, { name: "", color: "" }), {
    action: "createSpace",
    payload: { name: "Music", icon: "🎧", color: "#b39df4", isPrivate: true },
  });
});
