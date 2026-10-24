import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import en from "./locales/en.json" with { type: "json" };
import fr from "./locales/fr.json" with { type: "json" };

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

test("every native string Lilo localizes has an en and a fr entry", () => {
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
	const missing = [...keys]
		.filter(([key]) => !(key in en.native) || !(key in fr.native))
		.map(([key, file]) => `${file}: ${JSON.stringify(key)}`);
	assert.deepEqual(missing, [], "add these strings to the native namespace of en.json and fr.json");
});

test("a French menu title keeps the ellipsis of its English one", () => {
	const mismatched = Object.entries(fr.native as Record<string, string>)
		.filter(([key, value]) => key.endsWith("\u2026") !== value.endsWith("\u2026"))
		.map(([key, value]) => `${JSON.stringify(key)}: ${JSON.stringify(value)}`);
	assert.deepEqual(mismatched, []);
});
