import { readFileSync } from "node:fs";
import type { Plugin } from "vite";
import { mediaForRelease } from "../release-media/catalog";
import { SUPPORTED_LOCALES } from "./src/lib/i18n/translate";
import { localizeReleaseEditorial, parseReleaseNotes, releaseHighlightsForVersion } from "./src/components/whatsnew/releaseNotes";

function bundledRelease(): string {
	const installed = (JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")) as { version: string }).version;
	const version = process.env.LILO_RELEASE_MEDIA_PREVIEW_VERSION || installed;
	if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error("Invalid release preview version");
	let markdown = "";
	try { markdown = readFileSync(new URL(`../.changes/v${version}.md`, import.meta.url), "utf8"); } catch { /* Development builds may not have prepared notes. */ }
	const release = parseReleaseNotes(markdown, version);
	release.media = mediaForRelease(version);
	const registry = JSON.parse(readFileSync(new URL("./src/components/whatsnew/releaseHighlights.json", import.meta.url), "utf8"));
	const editorial = releaseHighlightsForVersion(registry, version);
	release.editorial = {};
	for (const { code: locale } of SUPPORTED_LOCALES) {
		const catalog = JSON.parse(readFileSync(new URL(`./src/lib/i18n/locales/${locale}.json`, import.meta.url), "utf8"));
		release.editorial[locale] = localizeReleaseEditorial(editorial, catalog);
	}
	// The sheet shows notes only for the version the app reports: a preview presents its release as the installed one.
	release.version = installed;
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
