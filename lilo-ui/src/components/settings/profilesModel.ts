// Pure profile logic shared by the space editor, the Profiles settings and the space bar.
// i18n-free so it runs under tsx.

/** The Space color presets; profile avatars take the same pastels (Profile.palette in Swift). */
export const PASTEL_COLORS = [
  "#92a8ff",
  "#b39df4",
  "#f1a7a5",
  "#f4bb8c",
  "#e8d98f",
  "#9bd3b4",
  "#8fd5cf",
  "#9ac7eb",
  "#c3a5ea",
  "#f0a8c8",
  "#a7bcc7",
  "#c8ab98",
];

interface SpaceLike {
  id: string;
  profileId: string;
  isPrivate: boolean;
}

/** The user's profiles: every profile but the agents' throwaway one. */
export function userProfiles<P extends { id: string }>(profiles: P[], agentsProfileId: string): P[] {
  return agentsProfileId ? profiles.filter((profile) => profile.id !== agentsProfileId) : profiles;
}

/** The spaces signed in with each profile. A private space keeps nothing of its profile, and the
 * Agents space only borrows one, so neither counts as using it. */
export function spacesByProfile<S extends SpaceLike>(spaces: S[], agentsSpaceId: string): Map<string, S[]> {
  const usage = new Map<string, S[]>();
  for (const space of spaces) {
    if (space.isPrivate || space.id === agentsSpaceId) continue;
    const list = usage.get(space.profileId);
    if (list) list.push(space);
    else usage.set(space.profileId, [space]);
  }
  return usage;
}

/** The first pastel no profile wears yet, else the next in turn: what ProfileManager picks too. */
export function nextProfileColor(profiles: { color: string }[]): string {
  return (
    PASTEL_COLORS.find((color) => !profiles.some((profile) => profile.color === color)) ??
    PASTEL_COLORS[profiles.length % PASTEL_COLORS.length]
  );
}

/** What removing `profile` involves: the spaces to move and the user profiles that can take them.
 * The last user profile cannot go: a space always needs one to land in. */
export function profileRemoval<P extends { id: string }, S extends SpaceLike>(
  profile: P,
  users: P[],
  usage: Map<string, S[]>,
): { removable: boolean; targets: P[]; moving: S[] } {
  const targets = users.filter((candidate) => candidate.id !== profile.id);
  return { removable: targets.length > 0, targets, moving: usage.get(profile.id) ?? [] };
}
