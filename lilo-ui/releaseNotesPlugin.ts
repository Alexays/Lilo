import { readFileSync } from "node:fs";
import type { Plugin } from "vite";
import { SUPPORTED_LOCALES } from "./src/lib/i18n/translate";
import { generatedReleaseEditorial, localizeReleaseEditorial, parseReleaseNotes, releaseHighlightsForVersion } from "./src/components/whatsnew/releaseNotes";

function bundledRelease(): string {
	const version = (JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")) as { version: string }).version;
	let markdown = "";
	try { markdown = readFileSync(new URL(`../.changes/v${version}.md`, import.meta.url), "utf8"); } catch { /* Development builds may not have prepared notes. */ }
	const release = parseReleaseNotes(markdown, version);
	if (process.env.LILO_CAPTURE_BUILD === "1") return JSON.stringify(release);
	const registry = JSON.parse(readFileSync(new URL("./src/components/whatsnew/releaseHighlights.json", import.meta.url), "utf8"));
	const editorial = releaseHighlightsForVersion(registry, version);
	release.editorial = {};
	for (const { code: locale } of SUPPORTED_LOCALES) {
		const catalog = JSON.parse(readFileSync(new URL(`./src/lib/i18n/locales/${locale}.json`, import.meta.url), "utf8"));
		release.editorial[locale] = localizeReleaseEditorial(editorial, catalog);
	}
	let archive;
	try { archive = JSON.parse(readFileSync(new URL(`../site/src/assets/releases/${version}/capture.json`, import.meta.url), "utf8")); } catch { /* The capture build precedes the media archive. */ }
	if (archive?.schemaVersion === 3) {
		if (archive.release !== version || archive.approval?.passed !== true) throw new Error("Unapproved generated release content");
		for (const { code: locale } of SUPPORTED_LOCALES) release.editorial[locale] = generatedReleaseEditorial(archive, locale);
	}
	if (archive?.schemaVersion === 2 && archive.release === version && archive.visualReview?.passed === true) {
		for (const copy of Object.values(release.editorial)) {
			for (const highlight of copy?.highlights ?? []) {
				const scenario = highlight.illustration === "share" ? "tab-share" : highlight.illustration === "address" ? "address-bar" : "";
				const media = archive.recordings?.[scenario];
				if (media?.quality?.passed && Number.isFinite(media.durationMs) && media.durationMs > 0 && media.durationMs <= 15_000) {
					highlight.media = { poster: `/release-media/${scenario}-native.png`, recording: `/release-media/${scenario}-native.webp`, durationMs: media.durationMs, width: media.width, height: media.height };
				}
			}
		}
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
