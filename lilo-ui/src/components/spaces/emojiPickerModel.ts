// The emoji picker's catalog, search and skin tones. Loaded with the picker only: the dataset is its own chunk.

import type { Locale } from "../../lib/i18n/translate";
import { EMOJI_GROUPS } from "./emojiData.gen";

export interface EmojiEntry {
  emoji: string;
  name: string;
  /** Takes a skin tone modifier. */
  tones: boolean;
  /** Folded name and keywords, each word between spaces so a query word matches word starts or whole words. */
  terms: string;
  keywords: string;
}

export interface EmojiCatalog {
  categories: EmojiEntry[][];
  /** Keyed without FE0F and tone modifiers, so a remembered toned pick finds its name. */
  byBase: Map<string, EmojiEntry>;
}

/** The skin tone modifiers, by the index the setting stores; 0 is the default yellow. */
export const SKIN_TONES = ["", "\u{1F3FB}", "\u{1F3FC}", "\u{1F3FD}", "\u{1F3FE}", "\u{1F3FF}"];

const fold = (text: string) => text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().replace(/œ/g, "oe").replace(/æ/g, "ae").replace(/ß/g, "ss").replace(/ı/g, "i");
const wordsOf = (text: string) => fold(text).split(/[^\p{L}\p{N}]+/u).filter(Boolean);

function catalogOf(categories: EmojiEntry[][]): EmojiCatalog {
  return { categories, byBase: new Map(categories.flat().map((entry) => [entry.emoji.replace(/\uFE0F/g, ""), entry])) };
}

export const ENGLISH_EMOJI = catalogOf(
  EMOJI_GROUPS.map((group) =>
    group.split("\n").map((line) => {
      const [emoji, name, keywords = "", tones] = line.split("\t");
      return { emoji, name, tones: tones === "1", terms: ` ${wordsOf(name).join(" ")} `, keywords: ` ${keywords} ` };
    }),
  ),
);

// Each its own chunk, aligned line for line with EMOJI_GROUPS; English ships with the picker.
const LOCALE_NAMES: Partial<Record<Locale, () => Promise<{ EMOJI_NAMES: string }>>> = {
  fr: () => import("./emojiData.fr.gen"),
  es: () => import("./emojiData.es.gen"),
  "zh-Hans": () => import("./emojiData.zh-Hans.gen"),
  "pt-BR": () => import("./emojiData.pt-BR.gen"),
  ru: () => import("./emojiData.ru.gen"),
  "uk": () => import("./emojiData.uk.gen"),
  "de": () => import("./emojiData.de.gen"),
  "ja": () => import("./emojiData.ja.gen"),
};
const catalogs = new Map<Locale, Promise<EmojiCatalog>>();

/** The catalog named in `locale`, its English names and keywords still matching as keywords. */
export function loadEmojiCatalog(locale: Locale): Promise<EmojiCatalog> {
  const load = LOCALE_NAMES[locale];
  if (!load) return Promise.resolve(ENGLISH_EMOJI);
  let catalog = catalogs.get(locale);
  if (!catalog) {
    catalog = load().then(({ EMOJI_NAMES }) => {
      const lines = EMOJI_NAMES.split("\n");
      let index = 0;
      return catalogOf(
        ENGLISH_EMOJI.categories.map((category) =>
          category.map((english) => {
            const [name, keywords = ""] = lines[index++].split("\t");
            return { ...english, name, terms: ` ${wordsOf(name).join(" ")} `, keywords: ` ${keywords}${english.terms}${english.keywords}` };
          }),
        ),
      );
    });
    catalogs.set(locale, catalog);
  }
  return catalog;
}

export function emojiName(catalog: EmojiCatalog, emoji: string): string {
  return catalog.byBase.get(emoji.replace(/\uFE0F|[\u{1F3FB}-\u{1F3FF}]/gu, ""))?.name ?? emoji;
}

/** The modifier goes after the first code point, in place of its FE0F: the form Unicode lists for a single person. */
export function withTone(entry: EmojiEntry, tone: string): string {
  if (!tone || !entry.tones) return entry.emoji;
  const [first, ...rest] = entry.emoji;
  return first + tone + (rest[0] === "\uFE0F" ? rest.slice(1) : rest).join("");
}

/** Entries holding every query word at a word start: whole words of the name first, then name word
 * starts, then keywords. */
export function searchEmoji(catalog: EmojiCatalog, query: string): EmojiEntry[] {
  const words = wordsOf(query).map((word) => ` ${word}`);
  if (words.length === 0) return [];
  const ranks: EmojiEntry[][] = [[], [], []];
  for (const category of catalog.categories) {
    for (const entry of category) {
      if (words.every((word) => entry.terms.includes(`${word} `))) ranks[0].push(entry);
      else if (words.every((word) => entry.terms.includes(word))) ranks[1].push(entry);
      else if (words.every((word) => entry.terms.includes(word) || entry.keywords.includes(word))) ranks[2].push(entry);
    }
  }
  return ranks.flat();
}
