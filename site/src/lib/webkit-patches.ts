import type { Locale } from "./i18n";

// The patches table of docs/WEBKIT_FORK.md, translated; tests/test_site.py keeps both in step.
export const webkitPatches: {
  bug: number;
  pullRequest: number;
  fix: Record<Locale, string>;
}[] = [
  {
    bug: 329_822,
    fix: {
      en: "Removing or changing a style sheet no longer recomputes the style of every element. On Gmail, one removal goes from 25 ms to 4 ms.",
      fr: "Retirer ou modifier une feuille de style ne recalcule plus le style de chaque élément. Sur Gmail, un retrait passe de 25 ms à 4 ms.",
    },
    pullRequest: 79_315,
  },
  {
    bug: 328_920,
    fix: {
      en: "Images with sizes=auto stop requesting their source again each time their width changes, which could starve the page.",
      fr: "Les images en sizes=auto ne redemandent plus leur source à chaque changement de largeur, ce qui pouvait bloquer la page.",
    },
    pullRequest: 79_337,
  },
  {
    bug: 329_909,
    fix: {
      en: "Changing a CSS variable that a whole page inherits stops comparing every element's variables in full. With a design system's 2000 variables, 44 ms becomes 10 ms.",
      fr: "Changer une variable CSS héritée par toute la page ne compare plus en entier les variables de chaque élément. Avec les 2000 variables d'un design system, 44 ms deviennent 10 ms.",
    },
    pullRequest: 79_412,
  },
];
