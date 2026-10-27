import type { ImageMetadata } from "astro";
import { getImage } from "astro:assets";

import bitwarden from "../../../lilo-ui/public/password-managers/nngceckbapebfimnlniiiahkandclblb.png?inline";
import blueprint from "../../../Lilo/Resources/AppIcons/blueprint.png";
import clay from "../../../Lilo/Resources/AppIcons/clay.png";
import frost from "../../../Lilo/Resources/AppIcons/frost.png";
import graphite from "../../../Lilo/Resources/AppIcons/graphite.png";
import neon from "../../../Lilo/Resources/AppIcons/neon.png";
import night from "../../../Lilo/Resources/AppIcons/night.png";
import pixel from "../../../Lilo/Resources/AppIcons/pixel.png";
import pride from "../../../Lilo/Resources/AppIcons/pride.png";
import riso from "../../../Lilo/Resources/AppIcons/riso.png";
import spring from "../../../Lilo/Resources/AppIcons/spring.png";
import alexays from "../assets/demo/alexays.jpg";
import board from "../assets/demo/board.svg?url";
import browser from "../assets/demo/browser.svg?url";
import codex from "../assets/demo/codex.png?inline";
import github from "../assets/demo/github.svg?url";
import classic from "../assets/demo/lilo-classic.png";
import music from "../assets/demo/music.svg?url";
import notes from "../assets/demo/notes.svg?url";
import travel from "../assets/demo/travel.svg?url";
import darkReader from "../assets/extensions/dark-reader.png?inline";
import type { DemoAssets } from "../demo/assets";

const optimize = async (src: ImageMetadata, width: number) => {
  const image = await getImage({ format: "webp", quality: 90, src, width });

  return image.src;
};

export const getDemoAssets = async (): Promise<DemoAssets> => ({
  appIcons: await Promise.all(
    (
      [
        ["classic", classic],
        ["night", night],
        ["frost", frost],
        ["blueprint", blueprint],
        ["riso", riso],
        ["pixel", pixel],
        ["neon", neon],
        ["graphite", graphite],
        ["spring", spring],
        ["pride", pride],
        ["clay", clay],
      ] as const
    ).map(async ([id, src]) => ({
      dataURL: await optimize(src, 128),
      id,
    }))
  ),
  images: {
    alexays: await optimize(alexays, 64),
    bitwarden,
    board,
    browser,
    codex,
    darkReader,
    github,
    lilo: "/favicon.svg",
    music,
    notes,
    travel,
  },
});
