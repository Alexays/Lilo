import assert from "node:assert/strict";
import test from "node:test";
import { generatedReleaseEditorial, localizeReleaseEditorial, parseReleaseNotes, releaseHighlightsForVersion } from "./releaseNotes";
import registry from "./releaseHighlights.json";
import { catalogs, loadCatalog, SUPPORTED_LOCALES } from "../../lib/i18n/translate";
import archive080 from "../../../../site/src/assets/releases/0.8.0/capture.json";
import presentation080 from "../../../../site/src/assets/releases/0.8.0/presentation.json";

test("0.8.0 shares the same still and MP4 presentation in native What's New", () => {
	const editorial = generatedReleaseEditorial(archive080, "en", presentation080.media);
	assert.equal(editorial?.highlights[0].media?.kind, "image");
	assert.equal(editorial?.highlights[1].media?.kind, "video");
	assert.equal(editorial?.highlights[1].media?.recording, "/release-media/tab-sharing-controls-remotion.mp4");
});

test("the installed release keeps every change, continuation and group in order", () => {
	const notes = parseReleaseNotes(`## [1.2.3] - 2026-10-27

### Added

- Notice unread messages.
  Counts appear on favorites too.
- Keep <example> as text.

### Fixed

- Keep calls running.

[1.2.3]: https://example.com/compare/1.2.2...1.2.3

## [1.2.2] - 2026-10-20

### Added
- An older feature.
`, "1.2.3");
	assert.deepEqual(notes, {
		version: "1.2.3", date: "2026-10-27",
		groups: [
			{ kind: "Added", entries: ["Notice unread messages.\nCounts appear on favorites too.", "Keep <example> as text."] },
			{ kind: "Fixed", entries: ["Keep calls running."] },
		],
	});
});

test("missing or mismatched release notes never borrow another version's changes", () => {
	for (const source of ["", "## [1.2.2] - 2026-10-27\n### Fixed\n- Old change."]) {
		assert.deepEqual(parseReleaseNotes(source, "1.2.3"), { version: "1.2.3", date: "", groups: [] });
	}
});

test("an invalid release date is omitted without losing the changes", () => {
	const notes = parseReleaseNotes("## [1.2.3] - 2026-02-30\n### Fixed\n- A useful fix.", "1.2.3");
	assert.equal(notes.date, "");
	assert.deepEqual(notes.groups, [{ kind: "Fixed", entries: ["A useful fix."] }]);
});

const highlight = { illustration: "unread" as const, titleKey: "whatsNew.releases.v060.unreadTitle", descriptionKey: "whatsNew.releases.v060.unreadDescription" };
const editorial = { headlineKey: "whatsNew.releases.v060.headline", descriptionKey: "whatsNew.releases.v060.description", highlights: [highlight] };

test("only the selected release's translated highlight copy is prepared for the lazy view", () => {
	const catalog = { whatsNew: { releases: { v060: { headline: "Small improvements.", description: "A better everyday.", unreadTitle: "Catch up.", unreadDescription: "Unread counts on tabs." } } } };
	assert.deepEqual(localizeReleaseEditorial(editorial, catalog), {
		headline: "Small improvements.", description: "A better everyday.",
		highlights: [{ illustration: "unread", title: "Catch up.", description: "Unread counts on tabs." }],
	});
	assert.equal(localizeReleaseEditorial(editorial, {}), null);
	assert.equal(localizeReleaseEditorial(null, catalog), null);
});

test("highlights belong to an exact version and are absent for a maintenance release", () => {
	assert.deepEqual(releaseHighlightsForVersion({ "1.2.3": editorial }, "1.2.3"), editorial);
	assert.equal(releaseHighlightsForVersion({ "1.2.2": editorial }, "1.2.3"), null);
});

test("malformed highlights are discarded and at most three valid highlights survive", () => {
	const entries = [null, { ...highlight, illustration: "missing" }, { ...highlight, titleKey: "" }, highlight, highlight, highlight, highlight];
	const result = releaseHighlightsForVersion({ "1.2.3": { ...editorial, highlights: entries } }, "1.2.3");
	assert.deepEqual(result?.highlights, [highlight, highlight, highlight]);
	for (const registry of [null, [], {}, { "1.2.3": { highlights: [highlight] } }, { "1.2.3": { ...editorial, highlights: [] } }]) {
		assert.equal(releaseHighlightsForVersion(registry, "1.2.3"), null);
	}
});

test("authored highlights resolve to translated copy in every shipped catalog", async () => {
	for (const { code } of SUPPORTED_LOCALES) await loadCatalog(code);
	for (const version of Object.keys(registry)) {
		const editorial = releaseHighlightsForVersion(registry, version);
		assert.ok(editorial, `${version}: invalid highlights`);
		const keys = [editorial.headlineKey, editorial.descriptionKey, ...editorial.highlights.flatMap((item) => [item.titleKey, item.descriptionKey])];
		for (const catalog of Object.values(catalogs)) {
			for (const key of keys) {
				const value = key.split(".").reduce<unknown>((node, segment) => typeof node === "object" && node !== null ? (node as Record<string, unknown>)[segment] : undefined, catalog);
				assert.ok(typeof value === "string" && value.length > 0, `${version}: missing ${key}`);
			}
		}
	}
});


test("generated maintenance editorial has no stale highlights or media", () => {
 const archive = { content: { en: { headline: "A little steadier.", description: "Reliability improvements.", highlights: [] } }, recordings: {} };
 assert.equal(generatedReleaseEditorial(archive, "en"), null);
});

test("generated editorial carries previously unknown native recordings", () => {
 const archive = { content: { en: { headline: "Catch up.", description: "Unread counts.", highlights: [{ id: "unread-counts", title: "Catch up.", description: "Read your new messages." }] } }, recordings: { "unread-counts": { poster: "unread-counts-native.png", recording: "unread-counts-native.webp", durationMs: 6000, width: 1120, height: 720, quality: { passed: true } } } };
 assert.equal(generatedReleaseEditorial(archive, "en")?.highlights[0].media?.recording, "/release-media/unread-counts-native.webp");
});
