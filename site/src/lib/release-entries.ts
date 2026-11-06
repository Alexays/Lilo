import changelog from "../../../CHANGELOG.md?raw";
import { parseChangelog } from "./changelog.ts";
import { parseReleaseStories } from "./release-stories";

export const releases = parseChangelog(changelog);

export const stories = parseReleaseStories(
  changelog,
  Object.values(
    import.meta.glob("../content/releases/*.json", {
      eager: true,
      import: "default",
    })
  )
);

if (releases.length === 0) {
  throw new Error("No published Changie releases found in CHANGELOG.md");
}
