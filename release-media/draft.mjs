import { execFileSync } from "node:child_process";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import { templates } from "./templates.mjs";

const root = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(root, "..");
const stories = path.join(repo, "site/src/content/releases");
const registry = path.join(repo, "lilo-ui/src/components/whatsnew/releaseHighlights.json");
const locales = path.join(repo, "lilo-ui/src/lib/i18n/locales");

const translated = z.object({ en: z.string(), fr: z.string() });
const Step = z.object({
  do: z.enum(["page", "call", "action", "click", "input", "wait", "shot"]),
  selector: z.string().nullable(),
  text: z.string().nullable(),
  value: z.string().nullable(),
  name: z.string().nullable(),
});
const Plan = z.object({ template: z.enum(templates), steps: z.array(Step) });
export const Draft = z.object({
  title: translated,
  introduction: translated,
  highlights: z.array(
    z.object({
      id: z.string(),
      title: translated,
      body: translated,
      notes: z.array(z.number()),
      illustration: z.string(),
      plan: Plan.nullable(),
    }),
  ),
  groups: z.array(z.object({ title: translated, notes: z.array(z.number()) })),
  translations: z.record(
    z.string(),
    z.object({
      headline: z.string(),
      description: z.string(),
      highlights: z.array(z.object({ title: z.string(), description: z.string() })),
    }),
  ),
});

export function parseNotes(markdown) {
  const notes = [];
  let kind = "";
  for (const line of markdown.split("\n")) {
    const heading = /^### (\w+)/.exec(line);
    if (heading) kind = heading[1];
    else if (kind && line.startsWith("- ")) notes.push({ kind, text: line.slice(2) });
  }
  return notes;
}

/** Fixes alone tell no story: their notes already say everything. */
export const worthAnEntry = (notes) => notes.some((note) => note.kind !== "Fixed");

/** The website story for `draft`, or the error that refuses it. */
export function storyFrom(version, draft, notes) {
  const text = (index) => {
    if (!notes[index]) throw Error(`Note ${index} does not exist`);
    return notes[index].text;
  };
  if (!draft.highlights.length || draft.highlights.length > 3)
    throw Error("Write one to three highlights");
  const ids = draft.highlights.map((highlight) => highlight.id);
  if (ids.some((id) => !/^[a-z][a-z0-9-]*$/.test(id)) || new Set(ids).size !== ids.length)
    throw Error("Highlight ids must be unique kebab-case words");
  const told = draft.highlights.flatMap((highlight) => highlight.notes);
  if (draft.highlights.some((highlight) => !highlight.notes.length))
    throw Error("Every highlight must list the notes it tells");
  const grouped = draft.groups.flatMap((group) => group.notes);
  if (new Set(grouped).size !== grouped.length) throw Error("A note belongs to a single group");
  const covered = new Set([...told, ...grouped]);
  const missing = notes.map((_, index) => index).filter((index) => !covered.has(index));
  if (missing.length) throw Error(`Notes without a place: ${missing.join(", ")}`);
  return {
    version,
    title: draft.title,
    introduction: draft.introduction,
    highlights: draft.highlights.map(({ id, title, body, notes: indexes }) => ({
      id,
      title,
      body,
      notes: indexes.map(text),
    })),
    groups: draft.groups
      .filter((group) => group.notes.length)
      .map(({ title, notes: indexes }) => ({ title, notes: indexes.map(text) })),
  };
}

const SHOTS = { hero: 1, compare: 2, image: 1 };

/** The capture plans of a draft by highlight id, refusing one that cannot run. */
export function plansFrom(draft, known) {
  const plans = {};
  for (const { id, plan } of draft.highlights) {
    if (!plan) continue;
    const shots = plan.steps.filter((step) => step.do === "shot").length;
    if (SHOTS[plan.template] ? shots !== SHOTS[plan.template] : shots < 2)
      throw Error(`The ${id} plan takes ${shots} shot(s), which ${plan.template} cannot show`);
    for (const { selector } of plan.steps)
      for (const [name] of selector?.matchAll(/[.#][a-zA-Z][\w-]*/g) ?? [])
        if (!known(name.slice(1))) throw Error(`The ${id} plan names ${name}, which no source has`);
    plans[id] = plan;
  }
  return plans;
}

const camel = (id) => id.replace(/-(\w)/g, (_, letter) => letter.toUpperCase());

/** The What's New registry entry and the copy every locale catalog gains under `key`. `drawn` lists the
 * illustrations WhatsNewArt draws: every highlight shows one, and a film replaces it once captured. */
export function whatsNewFrom(version, draft, story, drawn) {
  const key = `v${version.replaceAll(".", "")}`;
  const path = `whatsNew.releases.${key}`;
  return {
    key,
    entry: {
      headlineKey: `${path}.headline`,
      descriptionKey: `${path}.description`,
      highlights: story.highlights.map(({ id }, index) => {
        const { illustration } = draft.highlights[index];
        if (!drawn.includes(illustration))
          throw Error(`The ${id} highlight shows "${illustration}", which WhatsNewArt does not draw`);
        return {
          id,
          illustration,
          titleKey: `${path}.${camel(id)}Title`,
          descriptionKey: `${path}.${camel(id)}Description`,
        };
      }),
    },
    copy: (copy) => ({
      headline: copy.headline,
      description: copy.description,
      ...Object.fromEntries(
        story.highlights.flatMap(({ id }, index) => [
          [`${camel(id)}Title`, copy.highlights[index].title],
          [`${camel(id)}Description`, copy.highlights[index].description],
        ]),
      ),
    }),
  };
}

/** Catalogs carry hand-kept formatting, so the release goes in as text rather than a rewrite. */
export function withReleaseCopy(catalog, key, copy) {
  const anchor = /^(\t+)"releases": \{\n/m.exec(catalog);
  if (!anchor) throw Error("The catalog has no whatsNew.releases");
  const indent = `${anchor[1]}\t`;
  const lines = Object.entries(copy).map(
    ([name, value]) => `${indent}\t${JSON.stringify(name)}: ${JSON.stringify(value)}`,
  );
  const block = `${indent}"${key}": {\n${lines.join(",\n")}\n${indent}},\n`;
  const at = anchor.index + anchor[0].length;
  return catalog.slice(0, at) + block + catalog.slice(at);
}

const run = (command, ...args) =>
  execFileSync(command, args, { cwd: repo, encoding: "utf8", maxBuffer: 1 << 28 });

/** A published release's notes, or with no version, the pending ones. */
async function release(requested) {
  if (requested) {
    const notes = await readFile(path.join(repo, `.changes/v${requested}.md`), "utf8");
    return {
      version: requested,
      markdown: notes,
      ref: `v${requested}`,
      since: run("git", "describe", "--tags", "--abbrev=0", `v${requested}^`).trim(),
    };
  }
  const changie = process.env.CHANGIE;
  return {
    version: run(changie, "next", "auto").trim().replace(/^v/, ""),
    markdown: run(changie, "batch", "auto", "--dry-run", "--allow-no-changes=false"),
    ref: "HEAD",
    since: run(changie, "latest").trim(),
  };
}

async function examples() {
  const files = (await readdir(stories)).sort((a, b) =>
    b.localeCompare(a, "en", { numeric: true }),
  );
  return Promise.all(files.slice(0, 3).map((file) => readFile(path.join(stories, file), "utf8")));
}

const localeCodes = async () =>
  (await readdir(locales))
    .map((file) => path.basename(file, ".json"))
    .filter((code) => code !== "en" && code !== "fr");

/** What the changelog-draft skill drafts from. */
async function context({ version, markdown, ref, since }, notes) {
  return [
    `<examples>\n${(await examples()).join("\n")}\n</examples>`,
    `<commits>\n${run("git", "log", "--no-merges", "--format=%s%n%b", `${since}..${ref}`)}\n</commits>`,
    `<interface-changes>\n${run("git", "diff", `${since}..${ref}`, "--", "lilo-ui/src/**/*.svelte")}\n</interface-changes>`,
    `<locales>${(await localeCodes()).join(", ")}</locales>`,
    `<notes version="${version}">\n${notes.map((note, index) => `${index}. [${note.kind}] ${note.text}`).join("\n")}\n</notes>`,
  ].join("\n\n");
}

async function main() {
  const source = await release(process.env.LILO_RELEASE);
  const notes = parseNotes(source.markdown);
  const target = path.join(stories, `${source.version}.json`);
  if (await readFile(target).catch(() => null)) {
    console.log(`Release ${source.version} already has an entry`);
    return;
  }
  if (!worthAnEntry(notes)) {
    console.log(`Release ${source.version} has only fixes: no entry to draft`);
    return;
  }
  if (!process.env.LILO_DRAFT) {
    console.log(await context(source, notes));
    return;
  }
  const known = (name) => {
    try {
      run("git", "grep", "-qF", "--", name, "lilo-ui/src");
      return true;
    } catch {
      return false;
    }
  };
  const draft = Draft.parse(JSON.parse(await readFile(process.env.LILO_DRAFT, "utf8")));
  const story = storyFrom(source.version, draft, notes);
  const plans = plansFrom(draft, known);
  const copyIn = (lang) => ({
    headline: story.title[lang],
    description: story.introduction[lang],
    highlights: story.highlights.map(({ title, body }) => ({
      title: title[lang],
      description: body[lang],
    })),
  });
  const copies = { en: copyIn("en"), fr: copyIn("fr") };
  for (const code of await localeCodes()) {
    copies[code] = draft.translations[code];
    if (!copies[code]) throw Error(`The draft has no ${code} translation`);
    if (copies[code].highlights.length !== story.highlights.length)
      throw Error(`The ${code} translation lost a highlight`);
  }

  const listed = /const illustrations = \[([^\]]*)\]/.exec(
    await readFile(path.join(repo, "lilo-ui/src/components/whatsnew/releaseNotes.ts"), "utf8"),
  );
  const art = await readFile(path.join(repo, "lilo-ui/src/components/whatsnew/WhatsNewArt.svelte"), "utf8");
  const drawn = [...(listed?.[1] ?? "").matchAll(/"(\w+)"/g)]
    .map((match) => match[1])
    .filter((name) => art.includes(`kind === "${name}"`));
  const whatsNew = whatsNewFrom(source.version, draft, story, drawn);
  for (const [code, copy] of Object.entries(copies)) {
    const file = path.join(locales, `${code}.json`);
    await writeFile(
      file,
      withReleaseCopy(await readFile(file, "utf8"), whatsNew.key, whatsNew.copy(copy)),
    );
  }
  const highlights = JSON.parse(await readFile(registry, "utf8"));
  await writeFile(
    registry,
    `${JSON.stringify({ [source.version]: whatsNew.entry, ...highlights }, null, "\t")}\n`,
  );
  await writeFile(target, `${JSON.stringify(story, null, 2)}\n`);
  const folder = path.join(root, "plans", source.version);
  await mkdir(folder, { recursive: true });
  for (const [id, plan] of Object.entries(plans))
    await writeFile(path.join(folder, `${id}.json`), `${JSON.stringify(plan, null, 2)}\n`);
  console.log(`Drafted the ${source.version} entry: ${story.title.en}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
