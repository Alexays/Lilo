import assert from "node:assert/strict";
import test from "node:test";

import { EMOJI_CATEGORIES, SKIN_TONES, emojiName, searchEmoji, withTone } from "./emojiPickerModel";

const entry = (emoji: string) => EMOJI_CATEGORIES.flat().find((candidate) => candidate.emoji === emoji)!;

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
  assert.deepEqual(searchEmoji("Dog").slice(0, 2).map((found) => found.emoji), ["🐶", "🐕"]);
  assert.ok(searchEmoji("home").some((found) => found.emoji === "🏠"));
  assert.ok(searchEmoji("pinata").some((found) => found.emoji === "🪅"));
  assert.ok(searchEmoji("france").some((found) => found.emoji === "🇫🇷"));
  assert.ok(!searchEmoji("og").some((found) => found.emoji === "🐶"));
  assert.deepEqual(searchEmoji("  "), []);
  assert.equal(searchEmoji("red heart")[0].emoji, "❤️");
  assert.ok(searchEmoji("heart")[0].terms.includes(" heart "));
});

test("a skin tone follows the person's first code point, in place of its variation selector", () => {
  assert.equal(withTone(entry("👍"), SKIN_TONES[3]), "👍🏽");
  assert.equal(withTone(entry("☝️"), SKIN_TONES[1]), "☝🏻");
  assert.equal(withTone(entry("🧑‍💻"), SKIN_TONES[5]), "🧑🏿‍💻");
  assert.equal(withTone(entry("🐶"), SKIN_TONES[3]), "🐶");
  assert.equal(withTone(entry("👍"), SKIN_TONES[0]), "👍");
});

test("a remembered pick finds its name, toned or not", () => {
  assert.equal(emojiName("🦊"), "fox");
  assert.equal(emojiName("☝🏻"), "index pointing up");
  assert.equal(emojiName("✈️"), "airplane");
  assert.equal(emojiName("x"), "x");
});
