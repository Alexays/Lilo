import { readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { prepare, renderHighlight } from "./render.mjs";

const root = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(root, "..");

const readJson = async (file) => JSON.parse(await readFile(file, "utf8"));

/** Names the media of each rendered highlight, leaving the others as they are. */
export function withMedia(highlights, rendered) {
  return highlights.map((highlight) =>
    rendered[highlight.id] ? { ...highlight, media: rendered[highlight.id] } : highlight,
  );
}

async function main() {
  const version = process.env.LILO_RELEASE;
  const plans = path.join(root, "plans", version);
  const ids = (await readdir(plans)).map((file) => path.basename(file, ".json"));
  await prepare();

  const rendered = {};
  for (const id of ids) {
    const directory = path.join(repo, "build/release-media/shots", version, id);
    try {
      const failure = await readFile(path.join(directory, "failure.txt"), "utf8").catch(() => null);
      if (failure) throw Error(failure);
      const { template } = await readJson(path.join(plans, `${id}.json`));
      const shots = await readJson(path.join(directory, "shots.json"));
      rendered[id] = await renderHighlight({ version, id, template, directory, shots });
      console.log(`${id}: ${rendered[id]}`);
    } catch (error) {
      console.log(`${id}: stays text-only. ${error.message}`);
    }
  }

  const storyFile = path.join(repo, "site/src/content/releases", `${version}.json`);
  const story = await readJson(storyFile);
  story.highlights = withMedia(story.highlights, rendered);
  await writeFile(storyFile, `${JSON.stringify(story, null, 2)}\n`);

  const registryFile = path.join(repo, "lilo-ui/src/components/whatsnew/releaseHighlights.json");
  const registry = await readJson(registryFile);
  if (registry[version]) {
    registry[version].highlights = withMedia(registry[version].highlights, rendered);
    await writeFile(registryFile, `${JSON.stringify(registry, null, "\t")}\n`);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
