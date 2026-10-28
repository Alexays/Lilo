import { readFileSync } from "node:fs";
import type { Plugin } from "vite";
import { parseReleaseNotes, releaseHighlightsForVersion } from "./src/components/whatsnew/releaseNotes";

const moduleId = "virtual:lilo-release";

export function releaseNotesPlugin(): Plugin {
	return {
		name: "lilo-release-notes",
		resolveId(id) { return id === moduleId ? `\0${moduleId}` : undefined; },
		load(id) {
			if (id !== `\0${moduleId}`) return;
			const packagePath = new URL("./package.json", import.meta.url);
			const version = (JSON.parse(readFileSync(packagePath, "utf8")) as { version: string }).version;
			const notesPath = new URL(`../.changes/v${version}.md`, import.meta.url);
			const highlightsPath = new URL("./src/components/whatsnew/releaseHighlights.json", import.meta.url);
			for (const path of [packagePath, notesPath, highlightsPath]) this.addWatchFile(path.pathname);
			let markdown = "";
			try { markdown = readFileSync(notesPath, "utf8"); } catch { /* Development builds may not have prepared notes. */ }
			const release = parseReleaseNotes(markdown, version);
			release.editorial = releaseHighlightsForVersion(JSON.parse(readFileSync(highlightsPath, "utf8")), version);
			return `export default ${JSON.stringify(release)};`;
		},
	};
}
