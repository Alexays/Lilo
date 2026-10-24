export type Locale = "en" | "fr";

export const copy = {
  en: {
    changelog: "Changelog",
    changelogDescription:
      "New features, improvements and fixes in Lilo, a free, open-source browser for Mac. Read the release notes for every version.",
    changelogTitle: "Lilo changelog: what’s new in every release",
    download: "Download for Mac",
    footer: "Lilo, made on a Mac for Macs. macOS 26 or later.",
    github: "Releases on GitHub",
    heading: "A little better,",
    headingAccent: "every release.",
    home: "Lilo home",
    introduction:
      "New features, small improvements, and the fixes that make your day smoother.",
    languageNote: "",
    latest: "Latest release",
    moving: "Moving",
    movingTitle: "Moving to Lilo",
    navigation: "Main",
    privacy: "Privacy",
    releaseLink: "View on GitHub",
    releases: "Release notes",
    skip: "Skip to content",
    version: "Version",
  },
  fr: {
    changelog: "Nouveautés",
    changelogDescription:
      "Les nouvelles fonctions, améliorations et corrections de Lilo, un navigateur gratuit et open source pour Mac. Retrouvez les notes de chaque version.",
    changelogTitle: "Nouveautés de Lilo : les notes de chaque version",
    download: "Télécharger pour Mac",
    footer: "Lilo, conçu sur Mac pour le Mac. macOS 26 ou version ultérieure.",
    github: "Versions sur GitHub",
    heading: "Lilo s’améliore,",
    headingAccent: "à chaque version.",
    home: "Accueil Lilo",
    introduction:
      "De nouvelles fonctions, de petites améliorations et les corrections qui facilitent le quotidien.",
    languageNote: "Les notes de version sont rédigées en anglais.",
    latest: "Dernière version",
    moving: "Changer de navigateur",
    movingTitle: "Passer à Lilo",
    navigation: "Navigation principale",
    privacy: "Confidentialité",
    releaseLink: "Voir sur GitHub",
    releases: "Notes de version",
    skip: "Aller au contenu",
    version: "Version",
  },
} satisfies Record<Locale, Record<string, string>>;

export const localizedPath = (lang: Locale, path = "") =>
  `/${lang === "fr" ? "fr/" : ""}${path}`;
