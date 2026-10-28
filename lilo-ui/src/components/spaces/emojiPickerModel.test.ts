import assert from "node:assert/strict";
import test from "node:test";

import { ENGLISH_EMOJI, SKIN_TONES, emojiName, loadEmojiCatalog, searchEmoji, withTone } from "./emojiPickerModel";

const EMOJI_CATEGORIES = ENGLISH_EMOJI.categories;
const entry = (emoji: string) => EMOJI_CATEGORIES.flat().find((candidate) => candidate.emoji === emoji)!;
const found = (query: string) => searchEmoji(ENGLISH_EMOJI, query);

test("the catalog holds the nine categories, without skin tone variants or components", () => {
  assert.equal(EMOJI_CATEGORIES.length, 9);
  assert.equal(EMOJI_CATEGORIES[0][0].emoji, "😀");
  assert.equal(EMOJI_CATEGORIES[8].at(-1)?.name, "flag: Wales");
  const all = EMOJI_CATEGORIES.flat().map((candidate) => candidate.emoji);
  assert.ok(all.length > 1800);
  assert.ok(!all.some((emoji) => /[\u{1F3FB}-\u{1F3FF}]/u.test(emoji)));
  assert.ok(!all.includes("\u{1F9B0}"));
});

test("search matches word starts in names first, then keywords, ignoring case and accents", () => {
  assert.deepEqual(found("Dog").slice(0, 2).map((match) => match.emoji), ["🐶", "🐕"]);
  assert.ok(found("home").some((match) => match.emoji === "🏠"));
  assert.ok(found("pinata").some((match) => match.emoji === "🪅"));
  assert.ok(found("france").some((match) => match.emoji === "🇫🇷"));
  assert.ok(!found("og").some((match) => match.emoji === "🐶"));
  assert.deepEqual(found("  "), []);
  assert.equal(found("red heart")[0].emoji, "❤️");
  assert.ok(found("heart")[0].terms.includes(" heart "));
});

test("a skin tone follows the person's first code point, in place of its variation selector", () => {
  assert.equal(withTone(entry("👍"), SKIN_TONES[3]), "👍🏽");
  assert.equal(withTone(entry("☝️"), SKIN_TONES[1]), "☝🏻");
  assert.equal(withTone(entry("🧑‍💻"), SKIN_TONES[5]), "🧑🏿‍💻");
  assert.equal(withTone(entry("🐶"), SKIN_TONES[3]), "🐶");
  assert.equal(withTone(entry("👍"), SKIN_TONES[0]), "👍");
});

test("a remembered pick finds its name, toned or not", () => {
  assert.equal(emojiName(ENGLISH_EMOJI, "🦊"), "fox");
  assert.equal(emojiName(ENGLISH_EMOJI, "☝🏻"), "index pointing up");
  assert.equal(emojiName(ENGLISH_EMOJI, "✈️"), "airplane");
  assert.equal(emojiName(ENGLISH_EMOJI, "x"), "x");
});

test("under French, search and names follow the French annotations, English keywords still matching", async () => {
  const french = await loadEmojiCatalog("fr");
  const search = (query: string) => searchEmoji(french, query).map((match) => match.emoji);
  assert.equal(await loadEmojiCatalog("fr"), french);
  // The nine cat smileys come first, in catalog order.
  assert.deepEqual(search("chat").slice(9, 12), ["🐱", "🐈", "🐈‍⬛"]);
  assert.ok(search("cœur").includes("❤️"));
  assert.deepEqual(search("coeur rouge").slice(0, 1), ["❤️"]);
  assert.equal(search("fusée")[0], "🚀");
  assert.equal(search("FUSEE")[0], "🚀");
  assert.ok(search("cat").includes("🐱"));
  assert.equal(emojiName(french, "🐱"), "tête de chat");
  assert.equal(emojiName(french, "☝🏻"), "index pointant vers le haut");
  assert.equal(french.categories.flat().length, EMOJI_CATEGORIES.flat().length);
  assert.equal(await loadEmojiCatalog("en"), ENGLISH_EMOJI);
});

test("Simplified Chinese emoji names and keywords load on demand, with English search still available", async () => {
  const chinese = await loadEmojiCatalog("zh-Hans");
  const search = (query: string) => searchEmoji(chinese, query).map((match) => match.emoji);
  assert.equal(await loadEmojiCatalog("zh-Hans"), chinese);
  assert.equal(search("火箭")[0], "🚀");
  assert.ok(search("红心").includes("❤️"));
  assert.ok(search("猫").includes("🐱"));
  assert.ok(search("rocket").includes("🚀"));
  assert.equal(emojiName(chinese, "🚀"), "火箭");
  assert.ok(chinese.categories.flat().every((emoji) => emoji.name.length > 0));
  assert.equal(chinese.categories.flat().length, EMOJI_CATEGORIES.flat().length);
});

test("Spanish emoji names and searches preserve accents and English keywords", async () => {
  const spanish = await loadEmojiCatalog("es");
  const search = (query: string) => searchEmoji(spanish, query).map((match) => match.emoji);
  assert.equal(await loadEmojiCatalog("es"), spanish);
  assert.ok(search("corazón").includes("❤️"));
  assert.ok(search("CORAZON").includes("❤️"));
  assert.ok(search("cat").includes("🐱"));
  assert.equal(emojiName(spanish, "🚀"), "cohete");
  assert.equal(spanish.categories.flat().length, EMOJI_CATEGORIES.flat().length);
});

test("Portuguese emoji search ignores accents and retains English keywords", async () => {
  const portuguese = await loadEmojiCatalog("pt-BR");
  const search = (query: string) => searchEmoji(portuguese, query).map((match) => match.emoji);
  assert.equal(await loadEmojiCatalog("pt-BR"), portuguese);
  assert.equal(emojiName(portuguese, "🚀"), "foguete");
  assert.equal(search("foguete")[0], "🚀");
  assert.ok(search("coração").includes("❤️"));
  assert.deepEqual(search("coração"), search("CORACAO"));
  assert.ok(search("rocket").includes("🚀"));
  assert.deepEqual(portuguese.categories.map((category) => category.map((entry) => entry.emoji)),
    ENGLISH_EMOJI.categories.map((category) => category.map((entry) => entry.emoji)));
});

test("Russian emoji names and search load on demand and keep English search available", async () => {
  const russian = await loadEmojiCatalog("ru");
  const search = (query: string) => searchEmoji(russian, query).map((match) => match.emoji);
  assert.equal(await loadEmojiCatalog("ru"), russian);
  assert.equal(search("ракета")[0], "🚀");
  assert.ok(search("сердце").includes("❤️"));
  assert.ok(search("кошка").includes("🐱"));
  assert.ok(search("rocket").includes("🚀"));
  assert.equal(emojiName(russian, "🚀"), "ракета");
  assert.ok(russian.categories.flat().every((emoji) => emoji.name.length > 0));
  assert.equal(russian.categories.flat().length, EMOJI_CATEGORIES.flat().length);
});


test("Ukrainian emoji names load on demand and retain English search", async () => {
  const catalog = await loadEmojiCatalog("uk");
  assert.equal(await loadEmojiCatalog("uk"), catalog);
  assert.equal(emojiName(catalog, "🚀"), "ракета");
  assert.ok(searchEmoji(catalog, "ракета").some((entry) => entry.emoji === "🚀"));
  assert.ok(searchEmoji(catalog, "серце").some((entry) => entry.emoji === "❤️"));
  assert.ok(searchEmoji(catalog, "rocket").some((entry) => entry.emoji === "🚀"));
  assert.ok(catalog.categories.flat().every((entry) => entry.name.length > 0));
  assert.deepEqual(catalog.categories.map((category) => category.map((entry) => entry.emoji)),
    ENGLISH_EMOJI.categories.map((category) => category.map((entry) => entry.emoji)));
});
