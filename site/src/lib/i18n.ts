export type Locale = 'en' | 'fr';

export const copy = {
  en: {
    home: 'Lilo home',
    navigation: 'Main',
    skip: 'Skip to content',
    privacy: 'Privacy',
    moving: 'Moving',
    movingTitle: 'Moving to Lilo',
    footer: 'Lilo, made on a Mac for Macs. macOS 26 or later.',
    changelog: 'Changelog',
    changelogTitle: 'Lilo changelog: what’s new in every release',
    changelogDescription: 'New features, improvements and fixes in Lilo, a free, open-source browser for Mac. Read the release notes for every version.',
    releases: 'Release notes',
    heading: 'A little better,',
    headingAccent: 'every release.',
    introduction: 'New features, small improvements, and the fixes that make your day smoother.',
    download: 'Download for Mac',
    github: 'Releases on GitHub',
    latest: 'Latest release',
    version: 'Version',
    releaseLink: 'View on GitHub',
    languageNote: '',
  },
  fr: {
    home: 'Accueil Lilo',
    navigation: 'Navigation principale',
    skip: 'Aller au contenu',
    privacy: 'Confidentialité',
    moving: 'Changer de navigateur',
    movingTitle: 'Passer à Lilo',
    footer: 'Lilo, conçu sur Mac pour le Mac. macOS 26 ou version ultérieure.',
    changelog: 'Nouveautés',
    changelogTitle: 'Nouveautés de Lilo : les notes de chaque version',
    changelogDescription: 'Les nouvelles fonctions, améliorations et corrections de Lilo, un navigateur gratuit et open source pour Mac. Retrouvez les notes de chaque version.',
    releases: 'Notes de version',
    heading: 'Lilo s’améliore,',
    headingAccent: 'à chaque version.',
    introduction: 'De nouvelles fonctions, de petites améliorations et les corrections qui facilitent le quotidien.',
    download: 'Télécharger pour Mac',
    github: 'Versions sur GitHub',
    latest: 'Dernière version',
    version: 'Version',
    releaseLink: 'Voir sur GitHub',
    languageNote: 'Les notes de version sont rédigées en anglais.',
  },
} satisfies Record<Locale, Record<string, string>>;

export function localizedPath(lang: Locale, path = '') {
  return `/${lang === 'fr' ? 'fr/' : ''}${path}`;
}
