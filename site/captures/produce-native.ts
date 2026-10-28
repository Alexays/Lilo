import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import sharp from "sharp";
import type { z } from "zod";

import {
  artifactDigest,
  checkAuthoredArchive,
  publishAuthoredArchive,
  releaseIdentity,
} from "./authored-archive.ts";
import type { AuthoredArtifact } from "./authored-archive.ts";
import {
  editorialSchema,
  requireReview,
  reviewSchema,
  scenarioCheckpoints,
  scenarioSchema,
  selectionSchema,
  validateEditorial,
  validateScenario,
  validateRepairContract,
  validateSelection,
} from "./authored-model.ts";
import type { AuthoredScenario, Review } from "./authored-model.ts";
import {
  authorAgent,
  boundedRepair,
  runCaptureCommand,
} from "./authored-orchestration.ts";
import {
  digest,
  encodeNativeProof,
  nativeManifestSchema,
} from "./native-proof.ts";

const root = fileURLToPath(new URL("../../", import.meta.url));
const identity = releaseIdentity(root, process.env.LILO_CAPTURE_VERSION ?? "");
const { version } = identity;
const output = path.join(root, "site/src/assets/releases", version);

if (existsSync(output) && process.env.LILO_CAPTURE_REPLACE !== "1") {
  try {
    checkAuthoredArchive(output, identity);
    process.stdout.write(
      `Keeping quality-approved authored media for ${version}\n`
    );
    process.exit(0);
  } catch {
    process.stdout.write(
      `Regenerating stale or incomplete release media for ${version}\n`
    );
  }
}

mkdirSync(path.join(root, "build/release-media"), { recursive: true });

const work = mkdtempSync(path.join(root, "build/release-media", `${version}-`));

const agent = <T>(
  name: string,
  schema: z.ZodType<T>,
  prompt: string,
  images: string[] = []
) => authorAgent(root, work, name, schema, prompt, images);

const reviews: Record<string, Review> = {};
const notes = JSON.stringify(identity.notes);

const versions = JSON.parse(
  readFileSync(path.join(root, "lilo-ui/package.json"), "utf-8")
).version;

const tags = execFileSync(
  "git",
  ["tag", "--list", "v*", "--sort=-version:refname"],
  { cwd: root, encoding: "utf-8" }
)
  .trim()
  .split("\n");

const previous = tags.find(
  (tag) => /^v\d+\.\d+\.\d+$/u.test(tag) && tag !== `v${versions}`
);

const changes = previous
  ? execFileSync(
      "git",
      ["diff", "--stat", previous, "--", "Lilo", "lilo-ui/src"],
      { cwd: root, encoding: "utf-8" }
    ).slice(0, 18_000)
  : "No previous release tag is available; inspect the current implementation.";

const grounding = `Release ${version}, build ${identity.build}. Exact note bullets: ${notes}\nPrevious tag: ${previous ?? "unavailable"}. Change summary:\n${changes}\nInspect relevant current Lilo/ and lilo-ui/src/ implementation before deciding. Exclude the release automation itself from the feature selection.`;

const plan = await boundedRepair(
  "feature selection",
  async (attempt, feedback) => {
    const selection = validateSelection(
      await agent(
        `selection-${attempt}`,
        selectionSchema,
        `${grounding}\nSelect the one to three MOST IMPORTANT new visible improvements for people using Lilo. Group notes about the same feature. Rank by user impact and demonstration value; do not restrict the choice to old recordings or a fixed feature registry. Every exact bullet must occur once in decisions (capture or text), with a concrete reason. Every capture note belongs to one highlight. Do not omit a more important feature solely because recording is hard. An empty highlights array is only legitimate for a genuinely nonvisual maintenance release, with noMediaReason. Produce short polished English editorial copy (plain text, no HTML).\nPrevious failed selection diagnostics: ${feedback}`
      ),
      version,
      identity.notes
    );

    const review = await agent(
      `selection-review-${attempt}`,
      reviewSchema,
      `${grounding}\nIndependently audit this proposed ranking and exact note coverage: ${JSON.stringify(selection)}. Reject omitted more important visible features, old features presented as new, unsupported claims, or decisions driven by recorder limitations. One to three strongest visible stories is enough; not every visible fix needs a movie. Empty selection requires genuinely nonvisual maintenance. Do not require an artificial movie for a performance/reliability improvement whose visible outcome cannot honestly convey it. passed=true only when the selection represents the release well.`
    );

    requireReview(review, "selection");
    reviews.selection = review;

    return selection;
  }
);

const content = await boundedRepair(
  "editorial translation",
  async (attempt, feedback) => {
    const translated = validateEditorial(
      await agent(
        `content-${attempt}`,
        editorialSchema(identity.locales),
        `Translate this approved release editorial into every required locale. Keep IDs and ordering exact, concise natural copy, plain text. English should match the selection. Required locale codes: ${identity.locales.join(", ")}. Selection: ${JSON.stringify(plan)}\nPrevious failure: ${feedback}`
      ),
      plan,
      identity.locales
    );

    const review = await agent(
      `content-review-${attempt}`,
      reviewSchema,
      `Independently check these translated release highlights for correctness, fluent phrasing, locale coverage, unchanged feature meaning/ordering, plain text and concise copy. Reject invented claims or untranslated non-English passages. Selection: ${JSON.stringify(plan)}\nTranslations: ${JSON.stringify(translated)}`
    );

    requireReview(review, "content");
    reviews.content = review;

    return translated;
  }
);

const stage = mkdtempSync(path.join(work, "approved-"));
const recordings: AuthoredArtifact["recordings"] = {};
const scenarioDigests: Record<string, string> = {};

try {
  // oxlint-disable eslint/no-await-in-loop -- Native GUI recording and image encoding must run sequentially.
  for (const feature of plan.highlights) {
    let baseline: AuthoredScenario | undefined;

    const result = await boundedRepair(
      feature.id,
      async (attempt, feedback) => {
        const name = `${feature.id}-${attempt}`;
        const attemptDir = path.join(work, name);
        mkdirSync(attemptDir);

        const scenario = validateScenario(
          await agent(
            `${name}-author`,
            scenarioSchema,
            `${grounding}\nAuthor a complete NEW declarative native demo for the frozen feature ${JSON.stringify(feature)}. Read relevant source files for exact selectors, menu actions, settings keys and feature behavior. Read LiloTests/Window/ReleaseCaptureTests.swift, LiloTests/Support/AuthoredReleaseScenario.swift and site/captures/authored-model.ts for the fixed driver. The author cannot modify product code or quality gates. Do not copy old scenarios blindly.\nThe driver seeds tabs on an ephemeral local HTTPS server before capture, then executes ordinary UI events against the real compiled native Lilo window at 1120x720. The final seeded tab is active. Each target has surface (chrome/page/peek/native), selector and text (empty means any exact selector match). Native supports NSButton clicks and visible/absent only; menu selectors must exist in Lilo/App/MainMenu.swift and target MainWindowController. Use {{tab:seed-id}} in selectors and predicates for seeded UUIDs, and {{fixture:filename.html}} in fixture HTML or input text for local URLs. Fixture links may also use relative filenames. No arbitrary JS evaluation or state injection into chrome is available. Settings are initial seed values only.\nWrite attractive synthetic content with generic names, ample whitespace and legible type. Fixtures may use ordinary browser APIs such as getDisplayMedia when demonstrating real browser features; never imitate Lilo chrome, fake feature results or use external resources, shell commands, remote APIs, private user data, permissions that require user intervention, destructive actions or terminal tabs. Read at least one actual implementation path and cite it in evidence.\nShow an understandable before/action/after, calm intentional cursor movement and readable holds; aim for 6–12 seconds, always under 15 including movement. At least two assertions must prove meaningful visible feature states, not only fixture presence or an unchanged selected tab. posterCheckpoint must show the strongest visible completed state; hold that state >=2 seconds. Final hold >=2 seconds. Predicates for selected-tab/shared-tab use the seed ID itself, without template syntax. Do not weaken previous semantic goals to pass a repair.\nFrozen initial scenario (if present, retain its goal, assertion IDs/types/expected results and poster checkpoint exactly; selectors and fixtures may be repaired): ${JSON.stringify(baseline ?? null)}. Actual prior failure diagnostics (inspect files/frames in the paths if useful): ${feedback}\nWork directory: ${work}`
          ),
          feature.id
        );

        if (baseline) {
          validateRepairContract(baseline, scenario);
        } else {
          baseline = scenario;
        }

        for (const source of scenario.evidence) {
          if (!existsSync(path.join(root, source))) {
            throw new Error(`Missing implementation evidence: ${source}`);
          }
        }

        const scenarioPath = path.join(attemptDir, "scenario.json");
        const bytes = `${JSON.stringify(scenario, null, 2)}\n`;
        writeFileSync(scenarioPath, bytes);

        const authorReview = await agent(
          `${name}-author-review`,
          reviewSchema,
          `Independently audit this native demo before execution. Read its cited implementation and fixed driver. Feature/required meaning: ${JSON.stringify(feature)}. Scenario: ${bytes}. Initial semantic contract: ${JSON.stringify(baseline)}. Reject any weaker assertion target than the original feature state as well as fixture-generated fake browser UI/results, external resources/services, real user data, unsupported actions, dangerous paths or executable terminal content, permission flows needing a human, hidden state mutation during capture, wrong selectors, unrelated assertions, or a repair that dropped core feature behavior. At least two assertions must demonstrate the actual feature, and the poster state must be held clearly. No product code or gate changes are allowed. Synthetic page scripts using supported Web APIs to exercise Lilo are legitimate.`
        );

        requireReview(authorReview, `${feature.id} author`);
        const frames = path.join(attemptDir, "frames");
        await runCaptureCommand(
          root,
          "make",
          ["release-media-record", `SCENARIO=${scenarioPath}`, `OUT=${frames}`],
          path.join(attemptDir, "record.log"),
          "",
          240_000
        );
        const encoded = path.join(attemptDir, "encoded");
        const scenarioDigest = digest(bytes);

        const encodedRecordings = await encodeNativeProof(
          frames,
          encoded,
          version,
          false,
          identity.inputDigest,
          [
            {
              checkpoints: scenarioCheckpoints(scenario),
              id: feature.id,
              posterCheckpoint: scenario.posterCheckpoint,
              scenarioDigest,
            },
          ]
        );

        const manifest = nativeManifestSchema.parse(
          JSON.parse(
            readFileSync(
              path.join(frames, feature.id, "manifest.json"),
              "utf-8"
            )
          )
        );

        const chosen = new Set(
          [
            0,
            ...manifest.checkpoints.map((checkpoint) =>
              manifest.frames.findIndex(
                (frame) => frame.atMs >= checkpoint.atMs + 200
              )
            ),
            manifest.frames.length - 1,
          ].filter((index) => index >= 0)
        );

        const images: string[] = [];

        for (const index of chosen) {
          const image = path.join(attemptDir, `review-${index}.png`);
          await sharp(
            path.join(frames, feature.id, manifest.frames[index].file)
          )
            .png()
            .toFile(image);
          images.push(image);
        }

        images.push(path.join(encoded, `${feature.id}-native.png`));

        const visualReview = await agent(
          `${name}-visual-review`,
          reviewSchema,
          `You are the independent release-blocking visual gate. The last attached image is the published still poster; it must show the intended completed feature clearly. Inspect all preceding actual native frames in chronological order and read intermediate PNGs/timestamps in ${path.join(frames, feature.id)} as needed. Intended feature: ${JSON.stringify(feature)}. Scenario: ${bytes}. Manifest: ${JSON.stringify(manifest)}. Reject blank/incorrect states, fabricated results, prompts, insecure-page warnings, clipped controls, setup clutter, poor contrast/readability, confusing framing, rushed or mechanical cursor movement, or a feature not convincingly shown. Localhost and synthetic documents are expected. Check the before/action/after and final hold; require an Apple/Arc level of calm and polish. Do not accept purely technical success as visual quality. No person will repair or review this per release. All material problems must fail.`,
          images
        );

        requireReview(visualReview, `${feature.id} visual`);

        return {
          authorReview,
          encoded,
          recording: encodedRecordings[feature.id],
          scenarioDigest,
          scenarioPath,
          visualReview,
        };
      }
    );

    recordings[feature.id] = result.recording;
    scenarioDigests[feature.id] = result.scenarioDigest;
    reviews[`author:${feature.id}`] = result.authorReview;
    reviews[`visual:${feature.id}`] = result.visualReview;
    copyFileSync(
      result.scenarioPath,
      path.join(stage, `${feature.id}-scenario.json`)
    );

    for (const suffix of ["native.png", "native.webp", "source.json"]) {
      copyFileSync(
        path.join(result.encoded, `${feature.id}-${suffix}`),
        path.join(stage, `${feature.id}-${suffix}`)
      );
    }
  }

  // oxlint-enable eslint/no-await-in-loop
  const artifact: AuthoredArtifact = {
    appBuild: identity.build,
    content,
    inputDigest: identity.inputDigest,
    plan,
    recordings,
    release: version,
    scenarioDigests,
    schemaVersion: 3,
    source: "native",
  };

  writeFileSync(
    path.join(stage, "capture.json"),
    `${JSON.stringify({ ...artifact, approval: { digest: artifactDigest(artifact), passed: true, reviews } }, null, 2)}\n`
  );
  // Re-read source identity after every agent and native process to reject changes during production.
  publishAuthoredArchive(stage, output, releaseIdentity(root, version));
  process.stdout.write(
    `Authored release ${version} passed selection, content, native, encoding and visual gates: ${output}\nDiagnostics: ${work}\n`
  );
} finally {
  rmSync(stage, { force: true, recursive: true });
}
