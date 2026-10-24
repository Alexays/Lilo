import assert from "node:assert/strict";
import test from "node:test";

import { nextProfileColor, PASTEL_COLORS, profileRemoval, spacesByProfile, userProfiles } from "./profilesModel";

const profiles = [
  { id: "perso", color: PASTEL_COLORS[0] },
  { id: "work", color: PASTEL_COLORS[1] },
  { id: "agents", color: PASTEL_COLORS[2] },
];
const spaces = [
  { id: "home", profileId: "perso", isPrivate: false },
  { id: "music", profileId: "perso", isPrivate: false },
  { id: "docs", profileId: "work", isPrivate: false },
  { id: "incognito", profileId: "work", isPrivate: true },
  // The Agents space borrowing the user's Work profile.
  { id: "agents-space", profileId: "work", isPrivate: false },
];

test("the agents' throwaway profile is not one of the user's", () => {
  assert.deepEqual(userProfiles(profiles, "agents").map((profile) => profile.id), ["perso", "work"]);
  assert.equal(userProfiles(profiles, "").length, 3);
});

test("the Agents space and private spaces do not count as using a profile", () => {
  const usage = spacesByProfile(spaces, "agents-space");
  assert.deepEqual(usage.get("perso")?.map((space) => space.id), ["home", "music"]);
  assert.deepEqual(usage.get("work")?.map((space) => space.id), ["docs"]);
});

test("removing a used profile moves its spaces to one of the other user profiles", () => {
  const users = userProfiles(profiles, "agents");
  const removal = profileRemoval(users[1], users, spacesByProfile(spaces, "agents-space"));
  assert.equal(removal.removable, true);
  assert.deepEqual(removal.targets.map((profile) => profile.id), ["perso"]);
  assert.deepEqual(removal.moving.map((space) => space.id), ["docs"]);
});

test("the last user profile cannot be removed", () => {
  const users = userProfiles(profiles.slice(0, 1), "agents");
  const removal = profileRemoval(users[0], users, new Map());
  assert.equal(removal.removable, false);
  assert.deepEqual(removal.moving, []);
});

test("a new profile takes the first unworn pastel, then cycles", () => {
  assert.equal(nextProfileColor(profiles), PASTEL_COLORS[3]);
  assert.equal(nextProfileColor(PASTEL_COLORS.map((color) => ({ color }))), PASTEL_COLORS[0]);
});
