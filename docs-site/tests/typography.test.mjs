import assert from "node:assert/strict";
import { test } from "node:test";

import { typeset } from "../scripts/typography.mjs";

const NBSP = " ";
const NNBSP = " ";

test("French punctuation gets its no-break spaces and apostrophes are straight", () => {
  assert.equal(
    typeset("Choisissez un profil : **Réglages** ; prêt ? Oui ! « Ajouter à Lilo » l’app"),
    `Choisissez un profil${NBSP}: **Réglages**${NNBSP}; prêt${NNBSP}? Oui${NNBSP}! «${NBSP}Ajouter à Lilo${NBSP}» l'app`
  );
  assert.equal(typeset("**Date :** 2026"), `**Date${NBSP}:** 2026`);
});

test("typesetting twice changes nothing more", () => {
  const once = typeset("Un mot : « deux » ; trois ?");
  assert.equal(typeset(once), once);
});

test("code, kbd, link targets, frontmatter keys and colons inside words stay as written", () => {
  const untouched = [
    "---\ntitle: Réglages\ndescription: >-\n  Texte\n---",
    "Saisissez `: split` ou `a ; b`.",
    "```sh\necho a ; echo b ?\n```",
    "Appuyez sur <kbd>a ; b</kbd>.",
    "[Lien](/guides/a ? b) et [autre](/guides/c !)",
    "| Colonne | :--- |",
    "à 12 :30",
  ];
  for (const text of untouched) assert.equal(typeset(text), text);
});
