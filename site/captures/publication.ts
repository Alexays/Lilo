import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  checkPreparedRelease,
  readApprovedArchive,
  releaseIdentity,
} from "./authored-archive.ts";
import { checkPresentation } from "./remotion/presentation.ts";

export const checkPublication = (root: string) => {
  if (process.env.LILO_RELEASE_PREVIEW) {
    throw new Error("Preview media cannot be published");
  }

  const { version } = JSON.parse(
    readFileSync(path.join(root, "lilo-ui/package.json"), "utf-8")
  );

  const releases = path.join(root, "site/src/assets/releases");
  checkPreparedRelease(
    path.join(releases, version),
    releaseIdentity(root, version)
  );

  for (const entry of readdirSync(releases, { withFileTypes: true })) {
    if (
      !entry.isDirectory() ||
      !/^\d+\.\d+\.\d+$/u.test(entry.name) ||
      entry.name === version
    ) {
      continue;
    }

    const directory = path.join(releases, entry.name);
    const metadata = path.join(directory, "capture.json");

    if (
      existsSync(metadata) &&
      JSON.parse(readFileSync(metadata, "utf-8")).schemaVersion === 3
    ) {
      readApprovedArchive(directory);
    }

    if (existsSync(path.join(directory, "presentation.json"))) {
      checkPresentation(directory, { publication: true });
    }
  }
};

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  checkPublication(fileURLToPath(new URL("../../", import.meta.url)));
}
