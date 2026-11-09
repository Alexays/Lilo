import { readdirSync, readFileSync } from "node:fs";
import type { Plugin } from "vite";
import { localizeReleaseEditorial, parseReleaseNotes, releaseHighlightsForVersion } from "./src/components/whatsnew/releaseNotes.ts";

function bundledRelease(): string {
	const version = (JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")) as { version: string }).version;
	let markdown = "";
	try { markdown = readFileSync(new URL(`../.changes/v${version}.md`, import.meta.url), "utf8"); } catch { /* Development builds may not have prepared notes. */ }
	const release = parseReleaseNotes(markdown, version);
	const registry = JSON.parse(readFileSync(new URL("./src/components/whatsnew/releaseHighlights.json", import.meta.url), "utf8"));
	const editorial = releaseHighlightsForVersion(registry, version);
	release.editorial = {};
	const locales = new URL("./src/lib/i18n/locales/", import.meta.url);
	for (const file of readdirSync(locales)) {
		if (!file.endsWith(".json")) continue;
		release.editorial[file.slice(0, -5)] = localizeReleaseEditorial(editorial, JSON.parse(readFileSync(new URL(file, locales), "utf8")));
	}
	return JSON.stringify(release);
}

export function releaseNotesPlugin(): Plugin {
	return {
		name: "lilo-release-notes",
		generateBundle() { this.emitFile({ type: "asset", fileName: "release-notes.json", source: bundledRelease() }); },
		configureServer(server) {
			server.middlewares.use("/release-notes.json", (_request, response) => {
				response.setHeader("Content-Type", "application/json");
				response.end(bundledRelease());
			});
		},
	};
}
