import type { NativeCaptureSource } from "./presentation.ts";

export const storyTiming = (source: NativeCaptureSource) => {
  const checkpoint = (name: string) => {
    const time = source.footage.checkpoints.find(
      (item) => item.name === name
    )?.atMs;

    if (time === undefined) {
      throw new Error(`Missing native checkpoint: ${name}`);
    }

    return time;
  };

  const clipStart = checkpoint("brief-shared");

  const shownAt =
    5.4 + (checkpoint("share-shown-tab-available") - clipStart) / 1000;

  const switchedAt =
    5.4 + (checkpoint("share-switched-to-agenda") - clipStart) / 1000;

  if (switchedAt > 12) {
    throw new Error(
      "The native interaction leaves too little time for its result"
    );
  }

  return {
    clipStart,
    holdAfter: (checkpoint("agenda-sharing-preview") - clipStart + 200) / 1000,
    posterFrame: Math.min(780, Math.round((switchedAt + 1) * 60)),
    shownAt,
    switchedAt,
  };
};
