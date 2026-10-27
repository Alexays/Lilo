import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { catalogs, loadCatalog, SUPPORTED_LOCALES } from "./translate";

for (const { code } of SUPPORTED_LOCALES) await loadCatalog(code);

const appRoot = new URL("../../../../Lilo/", import.meta.url).pathname;
const literal = String.raw`"((?:[^"\\\n]|\\.)*)"`;

// Every way a Swift literal reaches `String.localized`: directly, through a ternary, or as an
// argument of a helper that localizes it.
const patterns = [
	new RegExp(String.raw`${literal}\s*\)?\.localized\b`, "g"),
	new RegExp(String.raw`\?\s*${literal}\s*:\s*${literal}\s*\)\.localized\b`, "g"),
	new RegExp(String.raw`\b(?:makeMenuItem|makeLinkItem|makeDownloadItem|add)\(\s*${literal}`, "g"),
	new RegExp(String.raw`\bAction\(\s*${literal}\s*,\s*${literal}\s*,\s*${literal}`, "g"),
	new RegExp(String.raw`\bsuccess:\s*(?:[^"{\n]*\?\s*)?${literal}(?:\s*:\s*${literal})?`, "g"),
];

function swiftFiles(dir: string): string[] {
	return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
		const path = join(dir, entry.name);
		if (entry.isDirectory()) return entry.name === "Generated" ? [] : swiftFiles(path);
		return entry.name.endsWith(".swift") ? [path] : [];
	});
}

test("every native string Lilo localizes has an entry in every catalog", () => {
	const keys = new Map<string, string>();
	for (const file of swiftFiles(appRoot)) {
		const source = readFileSync(file, "utf8");
		for (const pattern of patterns) {
			for (const match of source.matchAll(pattern)) {
				for (const raw of match.slice(1)) {
					// An interpolated literal has no fixed key; `Action`'s first argument is its id.
					if (raw === undefined || raw.includes("\\(") || (pattern === patterns[3] && raw === match[1])) continue;
					const key = raw.replace(/\\(["\\n])/g, (_, c: string) => (c === "n" ? "\n" : c));
					if (!keys.has(key)) keys.set(key, file.slice(appRoot.length));
				}
			}
		}
	}
	for (const { code } of SUPPORTED_LOCALES) {
		const native = catalogs[code]?.native as Record<string, string>;
		const missing = [...keys]
			.filter(([key]) => !(key in native))
			.map(([key, file]) => `${file}: ${JSON.stringify(key)}`);
		assert.deepEqual(missing, [], `add these strings to the native namespace of ${code}.json`);
	}
});

test("translated menu titles keep the ellipsis of their English ones", () => {
	for (const { code } of SUPPORTED_LOCALES) {
		const mismatched = Object.entries(catalogs[code]?.native as Record<string, string>)
			.filter(([key, value]) => key.endsWith("\u2026") !== value.endsWith("\u2026"))
			.map(([key, value]) => `${JSON.stringify(key)}: ${JSON.stringify(value)}`);
		assert.deepEqual(mismatched, [], code);
	}
});
