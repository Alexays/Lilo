import { readFileSync } from "node:fs";
import type { Plugin } from "vite";
import { SUPPORTED_LOCALES } from "./src/lib/i18n/translate";
import { localizeReleaseEditorial, parseReleaseNotes, releaseHighlightsForVersion } from "./src/components/whatsnew/releaseNotes";

function bundledRelease(): string {
	const version = (JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")) as { version: string }).version;
	let markdown = "";
	try { markdown = readFileSync(new URL(`../.changes/v${version}.md`, import.meta.url), "utf8"); } catch { /* Development builds may not have prepared notes. */ }
	const release = parseReleaseNotes(markdown, version);
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
		for (const { code: locale } of SUPPORTED_LOCALES) {
			const copy = archive.content[locale];
			if (!copy) throw new Error(`Missing approved release translation: ${locale}`);
			release.editorial[locale] = copy.highlights.length ? {
				headline: copy.headline, description: copy.description,
				highlights: copy.highlights.map((highlight: { id: string; title: string; description: string }) => {
					const media = archive.recordings[highlight.id];
					if (!media?.quality?.passed) throw new Error(`Missing approved media: ${highlight.id}`);
					return { title: highlight.title, description: highlight.description, media: { poster: `/release-media/${media.poster}`, recording: `/release-media/${media.recording}`, durationMs: media.durationMs, width: media.width, height: media.height } };
				}),
			} : null;
		}
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
