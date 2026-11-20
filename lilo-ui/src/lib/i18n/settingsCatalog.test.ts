import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";

const srcRoot = new URL("../../", import.meta.url).pathname;
const readsSettingsKey = /["'`]settings\.[a-zA-Z$]/;

function sources(dir: string): string[] {
	return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
		const path = join(dir, entry.name);
		if (entry.isDirectory()) return sources(path);
		return /\.(svelte|ts)$/.test(entry.name) && !entry.name.endsWith(".test.ts") ? [path] : [];
	});
}

// English `settings` copy is not in the first frame, so a reader outside the settings folder (whose
// components load through SettingsShell, SettingsPanel or SettingsBrowsingData) must load the catalog itself.
test("readers of settings.* outside components/settings import the deferred catalog", () => {
	const missing = sources(srcRoot).filter((path) => {
		if (path.includes("/components/settings/") || path.endsWith("/i18n/settingsCatalog.test.ts")) return false;
		const text = readFileSync(path, "utf8");
		return readsSettingsKey.test(text) && !text.includes("i18n/settingsCatalog");
	});
	assert.deepEqual(missing.map((path) => path.slice(srcRoot.length)), []);
});
