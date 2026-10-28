import { readFileSync } from "node:fs";
import type { Plugin } from "vite";
import { localizeReleaseEditorial, parseReleaseNotes, releaseHighlightsForVersion } from "./src/components/whatsnew/releaseNotes";

function bundledRelease(): string {
	const version = (JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")) as { version: string }).version;
	let markdown = "";
	try { markdown = readFileSync(new URL(`../.changes/v${version}.md`, import.meta.url), "utf8"); } catch { /* Development builds may not have prepared notes. */ }
	const release = parseReleaseNotes(markdown, version);
	const registry = JSON.parse(readFileSync(new URL("./src/components/whatsnew/releaseHighlights.json", import.meta.url), "utf8"));
	const editorial = releaseHighlightsForVersion(registry, version);
	release.editorial = {};
	for (const locale of ["en", "fr"] as const) {
		const catalog = JSON.parse(readFileSync(new URL(`./src/lib/i18n/locales/${locale}.json`, import.meta.url), "utf8"));
		release.editorial[locale] = localizeReleaseEditorial(editorial, catalog);
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
