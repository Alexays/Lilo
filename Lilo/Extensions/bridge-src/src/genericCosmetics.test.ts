// Tests for the DOM-driven generic cosmetics runtime (GenericCosmetics.js).
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fnv1a, keyedTable, tokenBuckets } from "./filterTables.testkit.ts";

const source = readFileSync(new URL("../../../ContentBlocker/GenericCosmetics.js", import.meta.url), "utf8");

interface FakeElement {
	nodeType: number;
	id: string;
	hostname?: string;
	classList: string[];
	querySelectorAll(sel: string): FakeElement[];
	appendChild?(node: unknown): void;
	isConnected?: boolean;
	chunks?: string[];
}

function el(id: string, classes: string[] = [], descendants: FakeElement[] = []): FakeElement {
	return {
		nodeType: 1,
		id,
		classList: classes,
		// "*" is every descendant; the attribute selectors only return what can carry a token.
		querySelectorAll: (sel: string) =>
			sel === "*" ? descendants : descendants.filter((d) => d.id || d.classList.length || d.hostname)
	};
}

function link(hostname: string): FakeElement {
	return { ...el(""), hostname };
}




interface Harness {
	styles: { chunks: string[] }[];
	frame: () => void;
	domContentLoaded: () => void;
	observing: () => boolean;
	observe: (records: { type: string; target?: FakeElement; addedNodes?: FakeElement[] }[]) => void;
	css: () => string;
	flushed: () => Promise<void>;
}

function run(
	table: { classes?: string[]; ids?: string[]; keyed?: Record<string, string[]>; links?: Record<string, string[]> },
	rootChildren: FakeElement[] = [],
	parsed: FakeElement[] | null = null,
	allowlist: string[] = [],
	host = "www.example.com",
	sites: Record<string, string[]> = {}
): Harness {
	const styles: { chunks: string[] }[] = [];
	let observerCallback: ((records: unknown[]) => void) | null = null;
	let observing = false;
	let frameCallback: (() => void) | null = null;
	let onDOMContentLoaded: (() => void) | null = null;

	const documentElement = {
		...el("", [], rootChildren),
		appendChild: (node: { isConnected: boolean }) => {
			node.isConnected = true;
		}
	};
	// `parsed` stands for the elements the parser has inserted so far; null means the DOM is complete.
	const doc = {
		readyState: parsed ? "loading" : "complete",
		getElementsByTagName: () => parsed ?? [],
		documentElement,
		head: null,
		createElement: () => {
			const style = {
				isConnected: false,
				chunks: [] as string[],
				appendChild(node: { text: string }) {
					style.chunks.push(node.text);
				}
			};
			styles.push(style);
			return style;
		},
		createTextNode: (text: string) => ({ text }),
		addEventListener: (type: string, cb: () => void) => {
			if (type === "DOMContentLoaded") onDOMContentLoaded = cb;
		}
	};
	class FakeMutationObserver {
		constructor(cb: (records: unknown[]) => void) {
			observerCallback = cb;
		}
		observe() {
			observing = true;
		}
	}
	const site = keyedTable(sites);
	const links = keyedTable(table.links ?? {});
	const keyed = keyedTable(table.keyed ?? {});
	const keys = Object.keys(table.keyed ?? {});
	const src = source
		.replace("__LILO_COSMETIC_CLASSES__", JSON.stringify(tokenBuckets(table.classes ?? [])))
		.replace("__LILO_COSMETIC_IDS__", JSON.stringify(tokenBuckets(table.ids ?? [])))
		.replace("__LILO_ALLOWLIST__", JSON.stringify(`|${allowlist.join("|")}|`))
		.replace("__LILO_SITE_INDEX__", JSON.stringify(site.index))
		.replace("__LILO_SITE_GROUPS__", JSON.stringify(site.groups))
		.replace("__LILO_SITE_TABLE__", JSON.stringify(site.entries))
		.replace("__LILO_LINK_INDEX__", JSON.stringify(links.index))
		.replace("__LILO_LINK_GROUPS__", JSON.stringify(links.groups))
		.replace("__LILO_LINK_TABLE__", JSON.stringify(links.entries))
		.replace("__LILO_KEYED_CLASSES__", JSON.stringify(tokenBuckets(keys.filter((k) => k[0] === ".").map((k) => k.slice(1)))))
		.replace("__LILO_KEYED_IDS__", JSON.stringify(tokenBuckets(keys.filter((k) => k[0] === "#").map((k) => k.slice(1)))))
		.replace("__LILO_KEYED_INDEX__", JSON.stringify(keyed.index))
		.replace("__LILO_KEYED_GROUPS__", JSON.stringify(keyed.groups))
		.replace("__LILO_KEYED_TABLE__", JSON.stringify(keyed.entries));
	const fn = new Function("self", "document", "MutationObserver", "requestAnimationFrame", "location", src);
	fn(
		{ CSS: { escape: (s: string) => s } },
		doc,
		FakeMutationObserver,
		(cb: () => void) => {
			frameCallback = cb;
		},
		{ host, hostname: host.replace(/:\d+$/, "") }
	);

	return {
		styles,
		frame: () => {
			const cb = frameCallback;
			frameCallback = null;
			cb?.();
		},
		domContentLoaded: () => {
			doc.readyState = "interactive";
			onDOMContentLoaded?.();
		},
		observing: () => observing,
		observe: (records) => observerCallback?.(records),
		css: () => styles.map((s) => s.chunks.join("")).join(""),
		flushed: () => Promise.resolve().then(() => {})
	};
}

describe("generic cosmetics", () => {
	test("only selectors whose token exists in the DOM are injected", async () => {
		const h = run(
			{ classes: ["ad-banner", "promo-box"], ids: ["sponsored"] },
			[el("", ["ad-banner", "content"]), el("main", ["layout"])]
		);
		await h.flushed();
		assert.ok(h.css().includes(".ad-banner{display:none!important}"));
		assert.ok(!h.css().includes("promo-box"));
		assert.ok(!h.css().includes("#sponsored"));
	});

	test("a token is only surveyed once however often it repeats", async () => {
		const many = Array.from({ length: 50 }, () => el("", ["ad-banner"]));
		const h = run({ classes: ["ad-banner"] }, many);
		await h.flushed();
		const occurrences = h.css().split(".ad-banner{").length - 1;
		assert.equal(occurrences, 1);
	});

	test("mutations reveal new matches, including attribute changes", async () => {
		const h = run({ classes: ["late-ad"], ids: ["overlay-ad"] }, []);
		await h.flushed();
		assert.equal(h.css(), "");

		h.observe([{ type: "childList", addedNodes: [el("", ["late-ad"])] }]);
		await h.flushed();
		assert.ok(h.css().includes(".late-ad{display:none!important}"));

		h.observe([{ type: "attributes", target: el("overlay-ad") }]);
		await h.flushed();
		assert.ok(h.css().includes("#overlay-ad{display:none!important}"));
	});

	test("link selectors are injected once a link to their host or a subdomain appears", async () => {
		const links = {
			"ads.example": ['a[href^="https://ads.example/"]'],
			"track.example": ['[href*="track.example/"]'],
			"other.example": ['a[href^="https://other.example/"]']
		};
		const h = run({ links }, [link("www.site.example"), link("cdn.ads.example")]);
		await h.flushed();
		assert.ok(h.css().includes('a[href^="https://ads.example/"]{display:none!important}'));
		assert.ok(!h.css().includes("track.example"));

		h.observe([{ type: "attributes", target: link("track.example") }]);
		h.observe([{ type: "childList", addedNodes: [link("x.ads.example")] }]);
		await h.flushed();
		assert.ok(h.css().includes('[href*="track.example/"]{display:none!important}'));
		assert.equal(h.css().split("ads.example/").length - 1, 1, "a host's selectors are injected once");
		assert.ok(!h.css().includes("other.example"));
	});

	test("while parsing, each frame surveys only the elements inserted since the last one", async () => {
		const parsed = [el("", ["ad-banner"])];
		const h = run({ classes: ["ad-banner", "late-ad", "tail-ad"] }, [], parsed);
		assert.equal(h.observing(), false, "no mutation observer while the parser inserts");

		h.frame();
		await h.flushed();
		assert.ok(h.css().includes(".ad-banner{display:none!important}"));

		parsed.push(el("", ["late-ad"]));
		h.frame();
		await h.flushed();
		assert.ok(h.css().includes(".late-ad{display:none!important}"));
		assert.equal(h.css().split(".ad-banner{").length - 1, 1);

		parsed.push(el("", ["tail-ad"]));
		h.domContentLoaded();
		await h.flushed();
		assert.ok(h.observing(), "the observer takes over once the DOM is complete");
		h.observe([{ type: "childList", addedNodes: [el("", ["tail-ad"])] }]);
		await h.flushed();
		assert.ok(h.css().includes(".tail-ad{display:none!important}"));
	});

	test("an observer batch walks a node-by-node inserted chain once", async () => {
		let reads = 0;
		let queries = 0;
		const counted = (node: FakeElement): FakeElement => {
			const query = node.querySelectorAll;
			return { ...node, querySelectorAll: (sel: string) => (queries++, query(sel)) };
		};
		const leaf: FakeElement = {
			nodeType: 1,
			id: "",
			get classList() {
				reads += 1;
				return ["late-ad"];
			},
			querySelectorAll: () => []
		};
		// Classless wrappers: the attribute selectors never return them, so only walking every
		// element marks them seen before their own records arrive.
		const middle = counted(el("", [], [leaf]));
		const parent = counted(el("", [], [middle, leaf]));
		const h = run({ classes: ["late-ad"] }, []);
		await h.flushed();

		// A script inserting node by node: one record each, parent first.
		h.observe([
			{ type: "childList", addedNodes: [parent] },
			{ type: "childList", addedNodes: [middle] },
			{ type: "childList", addedNodes: [leaf] }
		]);
		await h.flushed();
		assert.equal(queries, 1, "only the chain's root is queried");
		assert.equal(reads, 1);
		assert.ok(h.css().includes(".late-ad{display:none!important}"));
	});

	test("an allowlisted site installs nothing, with or without www", async () => {
		for (const entry of ["example.com", "www.example.com"]) {
			const h = run({ classes: ["ad-banner"] }, [el("", ["ad-banner"])], null, [entry]);
			await h.flushed();
			assert.equal(h.styles.length, 0);
		}
	});

	test("a hostless document is not taken for an allowlisted site", async () => {
		const h = run({ classes: ["ad-banner"] }, [el("", ["ad-banner"])], null, [], "");
		await h.flushed();
		assert.ok(h.css().includes(".ad-banner{display:none!important}"));
	});

	test("a site's selectors are injected at once, for the site, its subdomains and its entity", () => {
		const sites = { "example.com": [".site-ad"], "example.*": ["#entity-ad"], "other.com": [".other-ad"] };
		const h = run({}, [], null, [], "www.example.com", sites);
		assert.ok(h.css().includes(".site-ad{display:none!important}"));
		assert.ok(h.css().includes("#entity-ad{display:none!important}"));
		assert.ok(!h.css().includes("other-ad"));
	});

	test("a site exception drops a site or generic selector there", async () => {
		const sites = { "example.com": [".site-ad", ".kept"], "www.example.com": ["@.site-ad", "@.ad-banner"] };
		const h = run({ classes: ["ad-banner", "promo"] }, [el("", ["ad-banner", "promo"])], null, [], "www.example.com", sites);
		await h.flushed();
		assert.ok(!h.css().includes(".site-ad"));
		assert.ok(h.css().includes(".kept{display:none!important}"));
		assert.ok(!h.css().includes(".ad-banner"));
		assert.ok(h.css().includes(".promo{display:none!important}"));
	});

	test("a site :style() rule goes in as it is", () => {
		const h = run({}, [], null, [], "www.example.com", { "example.com": [".bar{height: 0 !important}", ".ad"] });
		assert.ok(h.css().includes(".bar{height: 0 !important}\n"));
		assert.ok(h.css().includes(".ad{display:none!important}"));
	});

	test("generichide keeps the site's selectors and turns generic ones off", async () => {
		const sites = { "example.com": ["@@", ".site-ad"] };
		const h = run({ classes: ["ad-banner"] }, [el("", ["ad-banner"])], null, [], "www.example.com", sites);
		await h.flushed();
		assert.ok(h.css().includes(".site-ad{display:none!important}"));
		assert.ok(!h.css().includes("ad-banner"));
		assert.equal(h.observing(), false);
	});

	test("the token hash matches the reference FNV-1a values Swift buckets by", () => {
		assert.deepEqual(["ad", "ad-banner", "promo"].map((t) => fnv1a(t)), [1193606232, 4152025673, 1943392768]);
	});

	test("an encoded site entry is decoded before use", () => {
		const h = run({}, [], null, [], "www.example.com", { "example.com": ['a[href=\xacx\xa4y\xac]', ".a\xb500e9"] });
		assert.ok(h.css().includes('a[href="x\\y"]{display:none!important}'));
		assert.ok(h.css().includes(".a\u00e9{display:none!important}"));
	});

	test("a complex selector is injected once its class or id appears", async () => {
		const h = run({ keyed: { ".ad-box": ["div.wrapper > .ad-box"], "#top-ad": ["aside#top-ad"] } }, [el("", ["ad-box"])]);
		await h.flushed();
		assert.ok(h.css().includes("div.wrapper > .ad-box{display:none!important}"));
		assert.ok(!h.css().includes("top-ad"));
		h.observe([{ type: "attributes", target: el("top-ad") }]);
		await h.flushed();
		assert.ok(h.css().includes("aside#top-ad{display:none!important}"));
	});

	test("an empty table installs nothing", () => {
		const h = run({}, [el("", ["anything"])]);
		assert.equal(h.styles.length, 0);
	});
});
