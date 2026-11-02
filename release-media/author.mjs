import { execFileSync } from "node:child_process";
import { readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fixtures } from "./fixtures.mjs";
import { sha, releaseSections, root as mediaRoot } from "./pipeline.mjs";

// Specific product capabilities, ordered by how much a demonstrated interaction explains.
const capabilities = [
  [
    "tab-share",
    /tab share picker|share (?:this|the shown|a different|another|the current) tab|switch(?:es|ing)? (?:the |a )?shared tab|chang(?:e|es|ing) (?:the )?shared tab/i,
  ],
];

const visualWords =
  /\b(?:button|card|picker|panel|dialog|sheet|menu|settings|sidebar|toolbar|layout|appearance|theme|icon|tab|space|view|pane|page|window|screen|preview|prompt)\b/i;

function bullets(markdown) {
  const result = [];
  let kind = "";
  for (const line of markdown.split("\n")) {
    const heading = /^### (\w+)/.exec(line);
    if (heading) kind = heading[1];
    else if (line.startsWith("- ")) result.push({ kind, text: line.slice(2) });
    else if (/^\s+\S/.test(line) && result.length) result.at(-1).text += `\n${line}`;
  }
  return result;
}

function internalChange({ kind, text }) {
  if (
    /^(?:\[release tooling\]|Release highlights use\b|Release media\b|Changelog (?:media|videos?)\b)/i.test(
      text,
    )
  )
    return true;
  if (
    kind === "Changed" &&
    !/^(?:(?:a|an|the) )?(?:new|adding|introducing)\b/i.test(text) &&
    !/\b(?:and|but|while|which|that)\b/i.test(text) &&
    /^[^.!?;:\n]+\b(?:uses?|consumes?|needs?|requires?) (?:less|fewer) (?:CPU(?: time| cycles)?|memory)\.?$/i.test(
      text,
    )
  )
    return true;
  return (
    !visualWords.test(text) &&
    /\b(?:API|MCP|AI agents?|bridge|CPU|memory|cache|prefetch|frames per second|frame rate|latency|timers?|echo cancellation)\b/i.test(
      text,
    )
  );
}

export function chooseMedia(version, markdown, catalog) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw Error(`Invalid release media version: ${version}`);
  const entries = catalog.releases ?? catalog;
  let existing = entries[version];
  const notesSha256 = sha(markdown);
  if (existing?.notesSha256 && existing.notesSha256 !== notesSha256) existing = undefined;
  if (existing) {
    if (!["video", "screenshot", "none"].includes(existing.kind) || !existing.reason?.trim())
      throw Error(`Missing media decision for ${version}`);
    if (existing.kind === "none") return { ...existing };
    const capability = capabilities.find(([feature]) => feature === existing.feature);
    if (
      !capability ||
      !existing.alt?.en ||
      !existing.alt?.fr ||
      !existing.notes?.length ||
      existing.notes.some((note) => !markdown.includes(note))
    )
      throw Error(
        `Missing native capability, translated description or exact source notes for ${version}`,
      );
    return { ...existing };
  }
  const changes = bullets(markdown).filter((note) =>
    ["Added", "Changed", "Breaking"].includes(note.kind),
  );
  const visual = changes.filter((note) => !internalChange(note));
  const unsupported = visual.find(
    (note) =>
      !capabilities.some(([, pattern]) => pattern.test(note.text)) &&
      (note.kind !== "Changed" || visualWords.test(note.text)),
  );
  if (unsupported)
    throw Error(
      `Release ${version} is blocked: no genuine native capture and HyperFrames storyboard supports: ${unsupported.text}. Add that capability in the feature pull request.`,
    );
  for (const [feature, pattern] of capabilities) {
    const matches = visual.filter((note) => pattern.test(note.text));
    if (!matches.length) continue;
    const fixture = fixtures[feature];
    const reference = entries[fixture];
    if (!reference || reference.feature !== feature || !reference.alt?.en || !reference.alt?.fr)
      throw Error(`Missing canonical native media recipe for ${feature} (${fixture})`);
    return {
      kind: reference.kind,
      feature,
      notesSha256,
      ...(feature === "tab-share" ? { variant: "share" } : {}),
      reason: "The release adds an interaction covered by a genuine native capture and motion recipe.",
      notes: matches.map((note) => note.text),
      alt: { ...reference.alt },
    };
  }
  return {
    kind: "none",
    notesSha256,
    reason: "Routine fixes or internal changes have no new visual interaction to demonstrate.",
  };
}

async function main() {
  const root = path.resolve(mediaRoot, "..");
  const file = path.join(root, "release-media/backlog.json");
  const catalog = JSON.parse(await readFile(file, "utf8"));
  const releases = releaseSections(await readFile(path.join(root, "CHANGELOG.md"), "utf8"));
  const selected = process.env.LILO_RELEASE_MEDIA_VERSION;
  const query = process.argv.includes("--fixture");
  if (query && !selected) throw Error("A selected RELEASE=x.y.z is required for media queries");
  const decisions = {};
  for (const version of selected ? [selected] : releases.keys()) {
    let notes = releases.get(version);
    if (!notes && /^\d+\.\d+\.\d+$/.test(version)) {
      try {
        notes = releaseSections(
          await readFile(path.join(root, `.changes/v${version}.md`), "utf8"),
        ).get(version);
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
    }
    if (!notes) throw Error(`Unknown release media version: ${version}`);
    decisions[version] = chooseMedia(version, notes, catalog);
  }
  if (query) {
    const entry = decisions[selected];
    console.log(fixtures[entry.feature] ?? "");
    return;
  }
  if (!selected) {
    for (const version of Object.keys(catalog.releases))
      if (!releases.has(version))
        throw Error(`Media decision has no published release: ${version}`);
    const pending = await readdir(path.join(root, ".changes/unreleased")).catch((error) => {
      if (error.code === "ENOENT") return [];
      throw error;
    });
    if (pending.some((name) => name.endsWith(".yaml"))) {
      if (!process.env.CHANGIE)
        throw Error("Use make release-media-author so pinned Changie can validate pending notes");
      const notes = execFileSync(
        process.env.CHANGIE,
        ["batch", "auto", "--dry-run", "--allow-no-changes=false"],
        { cwd: root, encoding: "utf8" },
      );
      const pendingVersion = releaseSections(notes).keys().next().value;
      if (!pendingVersion) throw Error("Changie did not produce a pending release to validate");
      chooseMedia(pendingVersion, notes, catalog);
    }
  }
  await writeFile(
    file,
    JSON.stringify(
      {
        ...catalog,
        releases: { ...catalog.releases, ...decisions },
      },
      null,
      2,
    ) + "\n",
  );
  console.log(`Verified automatic media selection for ${Object.keys(decisions).length} release(s)`);
}

if (import.meta.main) await main();
