// Shared formatting helpers.

import { type Locale, translate } from "./i18n/translate";

const BYTE_UNIT_KEYS = ["units.byte", "units.kilobyte", "units.megabyte", "units.gigabyte", "units.terabyte"];
const byteNumberFormats = new Map<string, Intl.NumberFormat>();

/**
 * A size in the locale's digits and units ("1.2 GB", "1,2 Go"): integers below GB, one decimal at GB,
 * or one decimal from KB when `precise` (a download's progress).
 */
export function formatByteSize(bytes: number, locale: Locale, precise = false): string {
	let exponent = 0;
	while (exponent < BYTE_UNIT_KEYS.length - 1 && bytes >= 1024 ** (exponent + 1)) exponent += 1;
	const digits = exponent >= (precise ? 1 : 3) ? 1 : 0;
	const key = `${locale}|${digits}`;
	let format = byteNumberFormats.get(key);
	if (!format) {
		format = new Intl.NumberFormat(locale, { minimumFractionDigits: digits, maximumFractionDigits: digits, useGrouping: false });
		byteNumberFormats.set(key, format);
	}
	return `${format.format(bytes / 1024 ** exponent)} ${translate(locale, BYTE_UNIT_KEYS[exponent])}`;
}

/** Unix-seconds timestamp as a locale date+time string. */
export function formatTimestamp(timestamp: number): string {
	return new Date(timestamp * 1000).toLocaleString();
}
