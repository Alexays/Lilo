import { spawn } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import sharp from "sharp";
import { z } from "zod";

import { parseChangelog } from "../src/lib/changelog.ts";
import { nativeInputDigest } from "./native-inputs.ts";
import {
  checkNativeArchive,
  encodeNativeProof,
  nativeScenarios,
  nativePlanSchema,
  nativeArchiveDigest,
} from "./native-proof.ts";

const root = fileURLToPath(new URL("../../", import.meta.url));
const version = process.env.LILO_CAPTURE_VERSION ?? "";

if (!/^\d+\.\d+\.\d+$/u.test(version)) {
  throw new Error("Use make release-media-proof RELEASE=x.y.z");
}

const appVersion = JSON.parse(
  readFileSync(path.join(root, "lilo-ui/package.json"), "utf-8")
).version;

if (appVersion !== version) {
  throw new Error(
    "Capture the current checkout's app version; historical recordings are preserved"
  );
}

const release = parseChangelog(
  readFileSync(path.join(root, "CHANGELOG.md"), "utf-8")
).find((r) => r.version === version);

if (!release) {
  throw new Error("Prepare this release's notes before recording");
}

const output = path.join(root, "site/src/assets/releases", version);

if (existsSync(output) && process.env.LILO_CAPTURE_REPLACE !== "1") {
  checkNativeArchive(output, version, true, "", nativeInputDigest(root));
  process.stdout.write(
    `Keeping quality-approved native media for ${version}\n`
  );
  process.exit(0);
}

const work = path.join(root, "build/release-media", version);

mkdirSync(work, { recursive: true });

// oxlint-disable-next-line promise/avoid-new -- The child process reports completion through events.
const run = (command: string, args: string[], input = "") =>
  // oxlint-disable-next-line promise/avoid-new -- Child process completion is an event-based API.
  new Promise<void>((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: root,
      stdio: ["pipe", "inherit", "inherit"],
    });

    child.stdin.end(input);
    child.on("error", reject);
    child.on("exit", (code) =>
      code === 0
        ? resolve()
        : reject(
            new Error(
              `${command} failed (${code}); release media remains blocked`
            )
          )
    );
  });

const agent = async <T>(
  name: string,
  schema: z.ZodType<T>,
  prompt: string,
  images: string[] = []
): Promise<T> => {
  const schemaPath = path.join(work, `${name}.schema.json`);
  const result = path.join(work, `${name}.json`);
  writeFileSync(schemaPath, JSON.stringify(z.toJSONSchema(schema)));
  await run(
    "codex",
    [
      "exec",
      "--ephemeral",
      "--sandbox",
      "read-only",
      "--ignore-user-config",
      "--output-schema",
      schemaPath,
      "--output-last-message",
      result,
      ...images.flatMap((image) => ["--image", image]),
      "-",
    ],
    prompt
  );

  return schema.parse(JSON.parse(readFileSync(result, "utf-8")));
};

const plan = await agent(
  "plan",
  nativePlanSchema,
  `This is an authorized, noninteractive release-media job. Do not ask questions or edit files. For this user-authorized first proof, select up to two NEW visible highlights among tab sharing and address-bar placement for Lilo ${version} from these exact release notes. Cite exact bullet text without the '- ' prefix. The first proof's native runners are tab-share (picker, live sharing, switch, stop), address-bar (Settings > Appearance > Hidden, command bar), and peek (Shift-click, close, reopen). Peek is additionally recorded as a reference proof but must not be claimed as new unless these notes actually introduce it. This implementation milestone covers tab sharing and address-bar placement, plus the separate Peek reference. Other release changes remain text for this proof; do not require separate recordings for localization, the What’s New sheet, or system audio. List unsupportedImportantFeatures only if a selected tab-sharing or address-bar demonstration cannot be covered by these runners. Output only the required JSON.\n${release.body}`
);

const sourceNotes = new Set(
  release.body
    .split("\n")
    .filter((line) => line.startsWith("- "))
    .map((line) => line.slice(2))
);

if (
  plan.version !== version ||
  plan.unsupportedImportantFeatures.length ||
  new Set(plan.highlights.map((h) => h.scenario)).size !==
    plan.highlights.length ||
  plan.highlights.some((h) => h.notes.some((note) => !sourceNotes.has(note)))
) {
  throw new Error(
    "The selected important features are unsupported or not grounded in this release; release blocked"
  );
}

const frames = process.env.LILO_CAPTURE_FRAMES || path.join(work, "frames");

if (!process.env.LILO_CAPTURE_FRAMES) {
  rmSync(frames, { force: true, recursive: true });
  await run("make", ["release-media-record", `OUT=${frames}`]);
}

const stage = mkdtempSync(path.join(work, "approved-"));

try {
  await encodeNativeProof(
    frames,
    stage,
    version,
    true,
    nativeInputDigest(root)
  );

  const archive = checkNativeArchive(
    stage,
    version,
    false,
    "",
    nativeInputDigest(root)
  );

  const reviewSchema = z.strictObject({
    passed: z.boolean(),
    problems: z.array(z.string()),
  });

  const reviews: Record<string, z.infer<typeof reviewSchema>> = {};

  // oxlint-disable eslint/no-await-in-loop -- Keep native movies and independent image reviews within one worker’s memory budget.
  for (const scenario of nativeScenarios) {
    const manifest = JSON.parse(
      readFileSync(path.join(frames, scenario, "manifest.json"), "utf-8")
    );

    const chosen = [
      0,
      ...manifest.checkpoints.map((c: { atMs: number }) =>
        manifest.frames.findIndex(
          (f: { atMs: number }) => f.atMs >= c.atMs + 200
        )
      ),
      manifest.frames.length - 1,
    ].filter((i) => i >= 0);

    const images = [];

    for (const index of new Set<number>(chosen)) {
      const target = path.join(work, `${scenario}-review-${index}.png`);
      await sharp(path.join(frames, scenario, manifest.frames[index].file))
        .png()
        .toFile(target);
      images.push(target);
    }

    reviews[scenario] = await agent(
      `review-${scenario}`,
      reviewSchema,
      `You are the independent visual quality gate for an authorized automated Lilo release recording. No questions or edits. Inspect these actual native frames in chronological order for scenario '${scenario}'. This proof uses synthetic pages on a local HTTPS fixture server; localhost is expected. Reject blank content, unexpected prompts, insecure-page warnings, clipped controls, illegible composition, setup clutter, inconsistent geometry, or a feature that is not visually demonstrated. Inspect the source manifest and intermediate frames in ${path.join(frames, scenario)} if needed; timing and state assertions have mechanical checks. Check for cursor teleportation and rushed/unreadable stages using frame timestamps. Prefer a calm Apple/Arc presentation. Every listed problem must be fixed before publication. Output passed=true only if there are no material problems. No human reviews this per release.\nManifest: ${JSON.stringify(manifest)}`,
      images
    );

    if (!reviews[scenario].passed || reviews[scenario].problems.length) {
      throw new Error(
        `${scenario} failed visual quality: ${reviews[scenario].problems.join("; ")}. Release blocked; frames and review kept in ${work}`
      );
    }
  }

  // oxlint-enable eslint/no-await-in-loop
  archive.plan = plan;
  archive.visualReview = {
    archiveDigest: nativeArchiveDigest(archive.recordings),
    passed: true,
    reviews,
  };
  writeFileSync(
    path.join(stage, "capture.json"),
    `${JSON.stringify(archive, null, 2)}\n`
  );
  checkNativeArchive(stage, version, true, "", nativeInputDigest(root));
  const backup = `${output}.previous`;

  if (existsSync(backup)) {
    throw new Error(
      "An interrupted archive replacement needs recovery before release"
    );
  }

  if (existsSync(output)) {
    renameSync(output, backup);
  }

  try {
    mkdirSync(path.dirname(output), { recursive: true });
    renameSync(stage, output);
  } catch (error) {
    if (existsSync(backup)) {
      renameSync(backup, output);
    }

    throw error;
  }

  rmSync(backup, { force: true, recursive: true });
  process.stdout.write(
    `Native media for ${version} passed feature, encoding and visual gates: ${output}\n`
  );
} finally {
  rmSync(stage, { force: true, recursive: true });
}
