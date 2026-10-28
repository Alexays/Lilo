import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

import { parseReleaseStories } from "../src/lib/release-stories.ts";

export const captureArchiveState = (
  directory: string,
  source: "demo" | "native" = "demo"
) => {
  const media =
    source === "native"
      ? ["peek-native.png", "peek-native.webp"]
      : [
          "peek-en-light.png",
          "peek-en-dark.png",
          "peek-fr-light.png",
          "peek-fr-dark.png",
          "peek-en-light.webp",
          "peek-en-dark.webp",
          "peek-fr-light.webp",
          "peek-fr-dark.webp",
        ];

  const present = ["capture.json", ...media].map((name) =>
    existsSync(`${directory}/${name}`)
  );

  if (present.every(Boolean)) {
    return "complete";
  }

  return present.some(Boolean) ? "incomplete" : "missing";
};

export const captureSourceDigest = (root: string) => {
  const paths = execFileSync(
    "git",
    [
      "ls-files",
      "-z",
      "--cached",
      "--others",
      "--exclude-standard",
      "--",
      "lilo-ui/src",
      "site/src/demo",
      "site/src/assets/demo",
      "site/src/lib/i18n.ts",
      "site/src/lib/demo-assets.ts",
      "site/src/lib/native-demo-data.ts",
      "site/src/pages/demo.astro",
      "site/package-lock.json",
    ],
    { cwd: root, encoding: "utf-8" }
  )
    .split("\0")
    .filter((path) => path && existsSync(`${root}/${path}`))
    .toSorted();

  const hash = createHash("sha256");

  for (const path of paths) {
    hash
      .update(path)
      .update("\0")
      .update(readFileSync(`${root}/${path}`));
  }

  return hash.digest("hex");
};

const main = () => {
  const version = process.env.LILO_CAPTURE_VERSION ?? "";

  if (!/^\d+\.\d+\.\d+$/u.test(version)) {
    throw new Error("Use make site-release-capture RELEASE=x.y.z");
  }

  const site = fileURLToPath(new URL("../", import.meta.url));

  const story = parseReleaseStories(
    readFileSync(`${site}/../CHANGELOG.md`, "utf-8"),
    [
      JSON.parse(
        readFileSync(`${site}/src/content/releases/${version}.json`, "utf-8")
      ),
    ]
  ).get(version);

  if (story && !story.capture) {
    process.stdout.write(`No recording for ${version}\n`);

    return;
  }

  const source = story?.capture?.source ?? "demo";

  const state = captureArchiveState(
    `${site}/src/assets/releases/${version}`,
    source
  );

  if (process.env.LILO_CAPTURE_REPLACE !== "1") {
    if (state === "complete") {
      process.stdout.write(`Keeping archived captures for ${version}\n`);

      return;
    }

    if (state === "incomplete") {
      throw new Error(
        `Incomplete archived captures for ${version}; use RECAPTURE=1 to replace them`
      );
    }
  }

  const require = createRequire(import.meta.url);

  if (source === "native") {
    throw new Error(
      "Native recordings need reviewed window frames; use make site-release-import RELEASE=x.y.z FRAMES=/path/to/manifest.json RECAPTURE=1"
    );
  }

  const result = spawnSync(
    process.execPath,
    [
      require.resolve("@playwright/test/cli"),
      "test",
      "--config=playwright.capture.config.ts",
    ],
    { cwd: site, stdio: "inherit" }
  );

  if (result.error) {
    throw result.error;
  }

  process.exitCode = result.status ?? 1;
};

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main();
}
