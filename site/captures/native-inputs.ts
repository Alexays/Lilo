import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

// Generated UI embeds contain the approved media metadata, so hash their sources instead.
export const nativeInputDigest = (root: string) => {
  const inputs = [
    "Lilo",
    "lilo-ui/src",
    "Xcode/Configs",
    "Lilo.xcodeproj",
    "Package.swift",
    "Package.resolved",
    "site/captures",
    "site/src/lib/changelog.ts",
    "site/src/content/releases",
    "Makefile",
    "project.yml",
    "CHANGELOG.md",
    ".changes/v*.md",
    "lilo-ui/package.json",
    "lilo-ui/package-lock.json",
    "lilo-ui/vite.config.ts",
    "lilo-ui/svelte.config.js",
    "lilo-ui/releaseNotesPlugin.ts",
    "LiloTests/Window/ReleaseCaptureTests.swift",
    "LiloTests/Support/ReleaseWindowRecorder.swift",
    "LiloTests/Support/AuthoredReleaseScenario.swift",
    "LiloTests/Agent/TinyHTTPServer.swift",
    "scripts/embed_chrome_ui.py",
    "scripts/generate_native_strings.py",
    "scripts/copy_release_media.py",
  ];

  const files = execFileSync(
    "git",
    [
      "ls-files",
      "-z",
      "--cached",
      "--others",
      "--exclude-standard",
      "--",
      ...inputs,
    ],
    { cwd: root, encoding: "utf-8" }
  )
    .split("\0")
    .filter(
      (file) =>
        file &&
        !file.startsWith("Lilo/Generated/") &&
        !file.endsWith(".test.ts") &&
        existsSync(path.join(root, file))
    )
    .toSorted();

  const hash = createHash("sha256");

  for (const file of files) {
    hash
      .update(file)
      .update("\0")
      .update(readFileSync(path.join(root, file)))
      .update("\0");
  }

  return hash.digest("hex");
};
