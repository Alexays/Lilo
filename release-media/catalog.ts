import backlog from "./backlog.json" with { type: "json" };

export interface ReleaseMedia {
  kind: "video" | "screenshot";
  poster: string;
  video?: string;
  width: number;
  height: number;
  alt: { en: string; fr: string };
}

type Entry = { kind: string; feature?: string; alt?: ReleaseMedia["alt"] };
const entries: Record<string, Entry> = backlog.releases;

export function mediaForRelease(version: string): ReleaseMedia | null {
  const entry = entries[version];
  if (!entry || entry.kind === "none") return null;
  if (!entry.feature || !entry.alt || (entry.kind !== "video" && entry.kind !== "screenshot"))
    throw new Error(`Invalid release media: ${version}`);
  const prefix = `/release-media/${version}/${entry.feature}`;
  return {
    kind: entry.kind,
    poster: `${prefix}.png`,
    ...(entry.kind === "video" ? { video: `${prefix}.mp4` } : {}),
    width: 1920,
    height: 1080,
    alt: entry.alt,
  };
}
