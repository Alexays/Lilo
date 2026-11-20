// Minimal ICU MessageFormat subset: {name} arguments, {n, plural|selectordinal|select, ...}
// with `=N` exact selectors and `offset:N`, and `#` for the formatted number inside plural
// options. Apostrophes are literal text (Lilo catalogs do not use ICU quoting, so French
// "l'onglet" needs no escaping: a deliberate deviation from full ICU). A malformed
// pattern degrades to its literal source instead of throwing.

export type Part = string | { arg: string } | { pound: true } | {
	arg: string;
	kind: "plural" | "selectordinal" | "select";
	offset: number;
	options: Array<[string, Part[]]>;
};

const WS = /\s/;
const KINDS = new Set(["plural", "selectordinal", "select"]);

// Read a run of non-delimiter characters starting at `i`; returns [word, next].
function word(src: string, i: number, stop: string): [string, number] {
	const start = i;
	while (i < src.length && !stop.includes(src[i])) i++;
	return [src.slice(start, i), i];
}

function space(src: string, i: number): number {
	while (i < src.length && WS.test(src[i])) i++;
	return i;
}

// Parse elements from `start` until the matching `}` or end of string; returns [parts, next].
// `inElement` distinguishes an option body (where `}` terminates) from the top level
// (where a stray `}` is literal text).
function parseParts(src: string, start: number, inPlural: boolean, inElement = false): [Part[], number] {
	const parts: Part[] = [];
	let text = "";
	let i = start;
	const flush = () => {
		if (text) parts.push(text);
		text = "";
	};
	while (i < src.length) {
		const ch = src[i];
		if (ch === "}" && inElement) {
			flush();
			return [parts, i + 1];
		}
		if (ch === "#" && inPlural) {
			flush();
			parts.push({ pound: true });
			i++;
			continue;
		}
		if (ch !== "{") {
			text += ch;
			i++;
			continue;
		}
		// A `{` that does not open a well-formed element stays literal text.
		let j = space(src, i + 1);
		const [name, nameEnd] = word(src, j, " \t\n,{}");
		j = space(src, nameEnd);
		if (!name || (src[j] !== "}" && src[j] !== ",")) {
			text += ch;
			i++;
			continue;
		}
		if (src[j] === "}") {
			flush();
			parts.push({ arg: name });
			i = j + 1;
			continue;
		}
		j = space(src, j + 1);
		const [type, typeEnd] = word(src, j, " \t\n,{}");
		j = space(src, typeEnd);
		if (!KINDS.has(type)) {
			// {n, number} and friends render like a plain argument; skip to the element's
			// end. A `{` inside means it was an unknown complex type, not a typed
			// argument - leave the element literal instead of swallowing its options.
			if (src[j] === "}" || src[j] === ",") {
				let depth = 0;
				let nested = false;
				while (j < src.length && (src[j] !== "}" || depth-- > 0)) j += src[j] === "{" ? (depth++, nested = true, 1) : 1;
				if (j < src.length && !nested) {
					flush();
					parts.push({ arg: name });
					i = j + 1;
					continue;
				}
			}
			text += ch;
			i++;
			continue;
		}
		const options: Array<[string, Part[]]> = [];
		let offset = 0;
		let ok = src[j] === "," ? true : false;
		if (ok) {
			j++;
			options: while (j < src.length) {
				j = space(src, j);
				if (src[j] === "}") break;
				const [sel, selEnd] = word(src, j, " \t\n{");
				j = space(src, selEnd);
				if (src[j] !== "{") {
					if (type !== "select" && sel.startsWith("offset:")) {
						offset = Number(sel.slice(7)) || 0;
						continue;
					}
					ok = false;
					break options;
				}
				// `#` binds to the nearest enclosing plural, so a plural context
				// propagates into nested select/selectordinal option bodies too.
				const [body, next] = parseParts(src, j + 1, inPlural || type !== "select", true);
				options.push([sel, body]);
				j = next;
			}
			j = space(src, j);
			// ICU requires `other` on every plural/selectordinal/select; without it a
			// message could render nothing, so the element falls back to literal text.
			ok = ok && src[j] === "}" && options.some(([sel]) => sel === "other");
		}
		if (!ok) {
			text += ch;
			i++;
			continue;
		}
		flush();
		parts.push({ arg: name, kind: type as "plural" | "selectordinal" | "select", offset, options });
		i = j + 1;
	}
	flush();
	return [parts, i];
}

export interface MessageContext {
	pluralRules: Intl.PluralRules;
	ordinalRules: Intl.PluralRules;
	numberFormat: Intl.NumberFormat;
}

// `pound` is the number `#` renders: the plural element's argument minus its offset.
function render(parts: Part[], params: Record<string, string | number>, ctx: MessageContext, pound: number): string {
	let out = "";
	for (const part of parts) {
		if (typeof part === "string") {
			out += part;
		} else if ("pound" in part) {
			out += ctx.numberFormat.format(pound);
		} else if (!("kind" in part)) {
			const value = params[part.arg];
			// `count` stays digit-grouped like the pre-ICU interpolator; other numbers are plain.
			out += value === undefined ? `{${part.arg}}`
				: part.arg === "count" && typeof value === "number" ? ctx.numberFormat.format(value)
				: String(value);
		} else {
			const raw = params[part.arg];
			const count = typeof raw === "number" ? raw : NaN;
			const key = part.kind === "select" ? String(raw ?? "other")
				: part.options.some(([sel]) => sel === `=${count}`) ? `=${count}`
				: (part.kind === "selectordinal" ? ctx.ordinalRules : ctx.pluralRules).select(count - part.offset);
			const pick = part.options.find(([sel]) => sel === key)?.[1]
				?? part.options.find(([sel]) => sel === "other")?.[1];
			// A select has no number of its own: `#` inside its options stays the
			// enclosing plural's pound.
			if (pick) out += render(pick, params, ctx, part.kind === "select" ? pound : count - part.offset);
		}
	}
	return out;
}

/** Parse `message` into parts; exported for the catalog parity test. */
export function parseMessage(message: string): Part[] {
	return parseParts(message, 0, false)[0];
}

const compiled = new Map<string, (params: Record<string, string | number>, ctx: MessageContext) => string>();

/** Format `message` (an ICU subset pattern) with `params`, compiling once per source string. */
export function formatMessage(
	message: string,
	params: Record<string, string | number>,
	ctx: MessageContext,
): string {
	let fn = compiled.get(message);
	if (!fn) {
		const [parts] = parseParts(message, 0, false);
		fn = (p, c) => render(parts, p, c, NaN);
		compiled.set(message, fn);
	}
	return fn(params, ctx);
}
