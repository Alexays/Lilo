import {
  existsSync,
  readFileSync,
  readdirSync,
  mkdirSync,
  renameSync,
  rmSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { z } from "zod";

import { parseChangelog, sourceReleaseNotes } from "../src/lib/changelog.ts";
import {
  editorialCopySchema,
  featureID,
  requireReview,
  reviewSchema,
  scenarioCheckpoints,
  selectionSchema,
  validateEditorial,
  validateScenario,
  validateSelection,
} from "./authored-model.ts";
import { nativeInputDigest } from "./native-inputs.ts";
import {
  digest,
  recordingSchema,
  validateNativeTimeline,
} from "./native-proof.ts";
import { checkPresentation } from "./remotion/presentation.ts";

const hash = z.string().regex(/^[a-f0-9]{64}$/u);

const artifactSchema = z.strictObject({
  appBuild: z.string().min(1),
  content: z.record(z.string(), editorialCopySchema),
  inputDigest: hash,
  plan: selectionSchema,
  recordings: z.record(featureID, recordingSchema),
  release: z.string(),
  scenarioDigests: z.record(featureID, hash),
  schemaVersion: z.literal(3),
  source: z.literal("native"),
});

export type AuthoredArtifact = z.infer<typeof artifactSchema>;

const approvalSchema = z.strictObject({
  digest: hash,
  passed: z.literal(true),
  reviews: z.record(z.string(), reviewSchema),
});

export type AuthoredArchive = AuthoredArtifact & {
  approval: z.infer<typeof approvalSchema>;
};

export interface ReleaseIdentity {
  version: string;
  build: string;
  inputDigest: string;
  notes: string[];
  locales: string[];
}

// Sorting every object also makes approval independent of JSON formatting and Zod field order.
export const artifactDigest = (artifact: AuthoredArtifact) =>
  digest(
    JSON.stringify(
      artifactSchema.parse(
        Object.fromEntries(
          Object.entries(artifact).filter(([key]) => key !== "approval")
        )
      ),
      (_key, value) => {
        // oxlint-disable-next-line anti-slop/no-runtime-typeof -- Canonicalize validated artifact JSON, rather than narrowing untrusted input.
        if (value && typeof value === "object" && !Array.isArray(value)) {
          return Object.fromEntries(
            Object.entries(value).toSorted(([a], [b]) => a.localeCompare(b))
          );
        }

        return value;
      }
    )
  );

export const releaseIdentity = (
  root: string,
  version: string
): ReleaseIdentity => {
  if (process.env.LILO_RELEASE_PREVIEW) {
    throw new Error("Preview media cannot prepare or publish a release");
  }

  if (!/^\d+\.\d+\.\d+$/u.test(version)) {
    throw new Error("Use RELEASE=x.y.z");
  }

  const appVersion = JSON.parse(
    readFileSync(path.join(root, "lilo-ui/package.json"), "utf-8")
  ).version;

  const config = readFileSync(
    path.join(root, "Xcode/Configs/Base.xcconfig"),
    "utf-8"
  );

  const build = config.match(/^CURRENT_PROJECT_VERSION\s*=\s*(?<build>\d+)/mu)
    ?.groups?.build;

  const nativeVersion = config.match(
    /^MARKETING_VERSION\s*=\s*(?<version>\S+)/mu
  )?.groups?.version;

  const release = parseChangelog(
    readFileSync(path.join(root, "CHANGELOG.md"), "utf-8")
  ).find((r) => r.version === version);

  const prepared = parseChangelog(
    readFileSync(path.join(root, `.changes/v${version}.md`), "utf-8")
  ).find((r) => r.version === version);

  if (
    appVersion !== version ||
    nativeVersion !== version ||
    !build ||
    !release ||
    !prepared ||
    release.body.trim() !== prepared.body.trim()
  ) {
    throw new Error(
      "Prepare matching app versions and release notes before generating media"
    );
  }

  return {
    build,
    inputDigest: nativeInputDigest(root),
    locales: readdirSync(path.join(root, "lilo-ui/src/lib/i18n/locales"))
      .filter((n) => n.endsWith(".json"))
      .map((n) => n.slice(0, -5))
      .toSorted(),
    notes: sourceReleaseNotes(release.body),
    version,
  };
};

export const parseApprovedArtifact = (
  raw: AuthoredArchive
): AuthoredArchive => {
  const { approval: inputApproval, ...data } = raw;
  const artifact = artifactSchema.parse(data);
  const approval = approvalSchema.parse(inputApproval);
  const ids = artifact.plan.highlights.map((h) => h.id).toSorted();

  if (
    ids.join("\0") !== Object.keys(artifact.recordings).toSorted().join("\0") ||
    ids.join("\0") !==
      Object.keys(artifact.scenarioDigests).toSorted().join("\0")
  ) {
    throw new Error(
      "Missing selected feature recording or authored scenario; release blocked"
    );
  }

  const reviews = [
    "selection",
    "content",
    ...ids.flatMap((id) => [`author:${id}`, `visual:${id}`]),
  ];

  for (const name of reviews) {
    const review = approval.reviews[name];

    if (!review) {
      throw new Error(`Missing ${name} quality review; release blocked`);
    }

    requireReview(review, name);
  }

  if (approval.digest !== artifactDigest(artifact)) {
    throw new Error("Approved release content or media was modified");
  }

  validateSelection(
    artifact.plan,
    artifact.release,
    artifact.plan.decisions.map((decision) => decision.note)
  );
  validateEditorial(
    artifact.content,
    artifact.plan,
    Object.keys(artifact.content)
  );

  return { ...artifact, approval };
};

export const checkAuthoredArchive = (
  directory: string,
  identity: ReleaseIdentity
): AuthoredArchive => {
  const raw = JSON.parse(
    readFileSync(path.join(directory, "capture.json"), "utf-8")
  );

  const { approval, ...artifact } = parseApprovedArtifact(raw);

  if (
    artifact.release !== identity.version ||
    artifact.appBuild !== identity.build ||
    artifact.inputDigest !== identity.inputDigest
  ) {
    throw new Error(
      "Release media belongs to another version, build or source input; release blocked"
    );
  }

  validateSelection(artifact.plan, identity.version, identity.notes);
  validateEditorial(artifact.content, artifact.plan, identity.locales);
  const ids = artifact.plan.highlights.map((highlight) => highlight.id);

  for (const id of ids) {
    const scenarioBytes = readFileSync(
      path.join(directory, `${id}-scenario.json`)
    );

    if (digest(scenarioBytes) !== artifact.scenarioDigests[id]) {
      throw new Error("Authored scenario changed after capture");
    }

    const scenario = validateScenario(
      JSON.parse(scenarioBytes.toString("utf-8")),
      id
    );

    const entry = artifact.recordings[id];

    const manifest = validateNativeTimeline(
      JSON.parse(
        readFileSync(path.join(directory, `${id}-source.json`), "utf-8")
      ),
      identity.version,
      identity.inputDigest,
      scenarioCheckpoints(scenario),
      artifact.scenarioDigests[id]
    );

    const finalCheckpoint = manifest.checkpoints.at(-1);

    if (!finalCheckpoint || manifest.durationMs - finalCheckpoint.atMs < 2000) {
      throw new Error("Native final state needs a measured two-second hold");
    }

    if (
      manifest.scenario !== id ||
      manifest.appBuild !== identity.build ||
      manifest.checkpoints.map((c) => c.name).join("\0") !==
        scenarioCheckpoints(scenario).join("\0") ||
      entry.sourceDigest !== digest(JSON.stringify(manifest)) ||
      entry.scenarioDigest !== artifact.scenarioDigests[id] ||
      entry.poster !== `${id}-native.png` ||
      entry.recording !== `${id}-native.webp`
    ) {
      throw new Error("Native capture does not match the authored scenario");
    }

    for (const [name, expected] of [
      [entry.poster, entry.posterDigest],
      [entry.recording, entry.recordingDigest],
    ]) {
      if (digest(readFileSync(path.join(directory, name))) !== expected) {
        throw new Error("Approved native media was modified");
      }
    }
  }

  return { ...artifact, approval };
};

export const checkPreparedRelease = (
  directory: string,
  identity: ReleaseIdentity
) => {
  const archive = checkAuthoredArchive(directory, identity);

  if (existsSync(path.join(directory, "presentation.json"))) {
    checkPresentation(directory, { publication: true });
  }

  return archive;
};

export const readApprovedArchive = (directory: string): AuthoredArchive => {
  const { approval: _approval, ...raw } = JSON.parse(
    readFileSync(path.join(directory, "capture.json"), "utf-8")
  );

  const artifact = artifactSchema.parse(raw);

  return checkAuthoredArchive(directory, {
    build: artifact.appBuild,
    inputDigest: artifact.inputDigest,
    locales: Object.keys(artifact.content),
    notes: artifact.plan.decisions.map((decision) => decision.note),
    version: artifact.release,
  });
};

export const publishAuthoredArchive = (
  stage: string,
  output: string,
  identity: ReleaseIdentity
) => {
  checkAuthoredArchive(stage, identity);
  const backup = `${output}.previous`;

  if (existsSync(backup)) {
    throw new Error(
      "An interrupted release archive needs recovery; release blocked"
    );
  }

  mkdirSync(path.dirname(output), { recursive: true });

  if (existsSync(output)) {
    renameSync(output, backup);
  }

  try {
    renameSync(stage, output);
  } catch (error) {
    if (existsSync(backup)) {
      renameSync(backup, output);
    }

    throw error;
  }

  rmSync(backup, { force: true, recursive: true });
};

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const root = fileURLToPath(new URL("../../", import.meta.url));

  const version =
    process.env.LILO_CAPTURE_VERSION ||
    JSON.parse(readFileSync(path.join(root, "lilo-ui/package.json"), "utf-8"))
      .version;

  checkPreparedRelease(
    process.env.LILO_CAPTURE_OUTPUT ||
      path.join(root, "site/src/assets/releases", version),
    releaseIdentity(root, version)
  );
}
