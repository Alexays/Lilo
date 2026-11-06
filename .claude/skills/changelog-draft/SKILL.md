---
name: changelog-draft
description: Draft a Lilo release's changelog entry (website story, What's New highlights and their copy in every catalog, media plans) from its release notes. Use when asked to draft, write or update the changelog entry, release story or What's New highlights of a release.
---

# Draft a changelog entry

You write the changelog of Lilo, a native macOS web browser built on WebKit. Readers are people who use Lilo every day, not developers of it. `make changelog-draft` checks your draft and writes every file from it; you never edit the story, the catalogs or `releaseHighlights.json` by hand.

## Steps

1. Run `make changelog-context`, with `RELEASE=x.y.z` for a published release (pending notes otherwise). It prints the numbered notes, the three latest entries as examples, the commits, the interface diff and the locales to translate into. Stop if it says the release already has an entry or has only fixes.
2. Write the draft to `build/changelog/<version>.json` in the shape below.
3. Run `make changelog-draft DRAFT=build/changelog/<version>.json`, with the same `RELEASE`. When it refuses the draft, fix the draft and run it again: nothing is written until every check passes.
4. Show the person the English and French story and wait for their review. Commit, push or open a pull request only when they ask. On a `changelog/<version>` branch, the **Changelog media** workflow films the highlights; locally, `make changelog-media RELEASE=x.y.z` does.

## Content

Write the entry from the release notes, using the commits only to understand what a note means. Every claim must come from a note: never invent a behavior, a number, a shortcut or a benefit. Commits can explain a note, but they never add a claim of their own.

```json
{
  "title": { "en": "...", "fr": "..." },
  "introduction": { "en": "...", "fr": "..." },
  "highlights": [
    { "id": "...", "title": { "en": "...", "fr": "..." }, "body": { "en": "...", "fr": "..." }, "notes": [0], "plan": null }
  ],
  "groups": [{ "title": { "en": "...", "fr": "..." }, "notes": [1, 2] }],
  "translations": {
    "de": { "headline": "...", "description": "...", "highlights": [{ "title": "...", "description": "..." }] }
  }
}
```

- `title`: a short headline in the voice of the example entries, three to six words, ending with a period. It names the release's theme, not a list of features.
- `introduction`: one sentence on what the reader gets, in plain words.
- `highlights`: one to three features worth a section, the ones a reader would tell a friend about. An `id` is a short kebab-case word. `title` is three to six words and ends with a period. `body` is one or two sentences, 45 words at most: open with what the reader can now do, then say how, naming the actual control or shortcut.
- `groups`: every note that is not a highlight, gathered under short area names such as "Sidebar", "Calls", "Agents" or "Performance". A group's title has no period. Use three to seven groups, ordered by how much a reader cares. A note goes in exactly one group. Fixes go with their area, not in a group of their own.
- `translations`: the English `title`, `introduction` and each highlight's `title` and `body`, translated into every locale `make changelog-context` lists, highlights in the same order. Natural, calm first-party product language, keeping the same meaning and product terms.

Refer to notes by their number in `notes`. A highlight lists the notes it tells; those notes then stay out of `groups`.

## Media

A highlight gets a `plan` when a picture says more than its words: it drives the real app and films the change. Leave `plan` null for anything the interface does not show.

A plan is `{ "template": "...", "steps": [...] }`. Pick the `template` that fits:

- `image`: one finished state. One shot.
- `hero`: one state worth a slow look. One shot.
- `compare`: a before and an after. Two shots.
- `flow`: an interaction, step by step. Two or more shots, with a `click` between them; a pointer travels to each click.

A step is `{ "do": "...", "selector": null, "text": null, "value": null, "name": null }`, unused fields null. Steps run in order in a fresh window with one Space, a sidebar on the left and no tabs.

- `page`: open a sample example.com page, with `text` as its title. Open at least one first.
- `call`: open a sample call, which shows the sidebar's call card.
- `action`: run the native command `name`: `openSettings`, `openHistory`, `editCurrentSpace`, `pinCurrentTab`, `newTab` or `toggleSidebar`.
- `click`: click the `selector`, narrowed to the element whose text is `text` when set.
- `input`: type `value` in the field at `selector`.
- `wait`: wait for `selector` to appear. Use it after anything that opens.
- `shot`: capture `selector`, as tight as the change allows. Close-ups read well and whole windows do not: leave `selector` null only when the whole window is the point.

Use only class names that appear in the interface diff, and only reach for what you can see there. The steps cannot drag, hover or use a keyboard shortcut: when a change needs one, leave `plan` null. Sample content is generic and invented, never a real site or person.

## Voice

Calm, plain and concrete, like a first-party Apple release note. Prefer "you" and the present tense. Show the benefit before the mechanism. Name interface items exactly as the notes do. No hype, no exclamation marks, no "we", no "now you can finally", no rhetorical questions, and no em dashes.

Use Lilo's own terms as the glossary spells them: Space, Private Space, Agents Space, pinned tab, favorite, folder, archive, Peek, Little window, Split View, command bar.

French is written, not translated: natural French with the same meaning, using "vous", with French typography (a non-breaking space before `:` `?` `!`). Keep the product terms Lilo's French interface uses in the example entries.
