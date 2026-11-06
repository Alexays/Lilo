import assert from "node:assert/strict";
import test from "node:test";

import { formatByteSize, formatTimestamp } from "./format";
import { loadCatalog } from "./i18n/translate";

test("formatByteSize rounds to integers below GB, one decimal at GB", () => {
	assert.equal(formatByteSize(512.6, "en"), "513 B");
	assert.equal(formatByteSize(2600, "en"), "3 KB");
	assert.equal(formatByteSize(134217728, "en"), "128 MB");
	assert.equal(formatByteSize(1.5 * 1024 ** 3, "en"), "1.5 GB");
});

test("formatByteSize keeps one decimal from KB when precise", () => {
	assert.equal(formatByteSize(512, "en", true), "512 B");
	assert.equal(formatByteSize(2048, "en", true), "2.0 KB");
	assert.equal(formatByteSize(5 * 1024 * 1024, "en", true), "5.0 MB");
	assert.equal(formatByteSize(6041430000, "en", true), "5.6 GB");
	assert.equal(formatByteSize(2.5 * 1024 ** 4, "en", true), "2.5 TB");
});

test("formatByteSize writes French digits and units", async () => {
	await loadCatalog("fr");
	assert.equal(formatByteSize(1.2 * 1024 ** 3, "fr"), "1,2 Go");
	assert.equal(formatByteSize(512, "fr"), "512 o");
	assert.equal(formatByteSize(5 * 1024 * 1024, "fr", true), "5,0 Mo");
	assert.equal(formatByteSize(2048, "fr", true), "2,0 Ko");
});

test("formatTimestamp follows the region of the locale", () => {
	const timestamp = new Date(2026, 5, 12, 14, 2, 5).getTime() / 1000;
	assert.equal(formatTimestamp(timestamp, "en-GB"), "12/06/2026, 14:02:05");
	assert.equal(formatTimestamp(timestamp, "en-US").replace(/\s/g, " "), "6/12/2026, 2:02:05 PM");
});
