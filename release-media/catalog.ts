export type ReleaseMediaKind = "film" | "loop" | "image";

export interface ReleaseMedia {
  kind: ReleaseMediaKind;
  poster: string;
  video?: string;
}

export const releaseMediaKinds: readonly ReleaseMediaKind[] = ["film", "loop", "image"];

/** A highlight's media lives at `assets/<version>/<highlight id>.{png,mp4}`. */
export function releaseMedia(version: string, id: string, kind: ReleaseMediaKind): ReleaseMedia {
  const path = `/release-media/${version}/${id}`;
  return { kind, poster: `${path}.png`, ...(kind === "image" ? {} : { video: `${path}.mp4` }) };
}
