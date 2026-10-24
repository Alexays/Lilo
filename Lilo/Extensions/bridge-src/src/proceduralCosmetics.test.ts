// Tests for the procedural cosmetics runtime (ProceduralCosmetics.js).
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { keyedTable } from "./filterTables.testkit.ts";

const source = readFileSync(new URL("../../../ContentBlocker/ProceduralCosmetics.js", import.meta.url), "utf8");

interface FakeElement {
	nodeType: number;
	textContent: string;
	style: { hidden: boolean; setProperty(name: string, value: string): void };
}

function el(textContent: string): FakeElement {
	const style = {
		hidden: false,
		setProperty(name: string, value: string) {
			if (name === "display" && value === "none") style.hidden = true;
		}
	};
	return { nodeType: 1, textContent, style };
}


/** A page element: matches `.className` only, its text is its own followed by its children's. */
class FakeNode {
	nodeType = 1;
	isConnected = true;
	parentElement: FakeNode | null = null;
	children: FakeNode[] = [];
	textReads = 0;
	style = {
		hidden: false,
		setProperty: (name: string, value: string) => {
			if (name === "display" && value === "none") this.style.hidden = true;
		},
		removeProperty: (name: string) => {
			if (name === "display") this.style.hidden = false;
		}
	};

	className: string;
	text: string;

	constructor(className: string, text = "") {
		this.className = className;
		this.text = text;
	}

	get textContent(): string {
		this.textReads++;
		return this.fullText();
	}

	fullText(): string {
		return this.text + this.children.map((c) => c.fullText()).join("");
	}

	append(child: FakeNode): FakeNode {
		child.parentElement = this;
		this.children.push(child);
		return child;
	}

	matches(css: string): boolean {
		return css === `.${this.className}`;
	}

	querySelectorAll(css: string): FakeNode[] {
		const own = css.replace(/^:scope /, "");
		return this.children.flatMap((c) => [...(c.matches(own) ? [c] : []), ...c.querySelectorAll(own)]);
	}

	get firstElementChild(): FakeNode | null {
		return this.children[0] ?? null;
	}

	get nextElementSibling(): FakeNode | null {
		const siblings = this.parentElement?.children ?? [];
		return siblings[siblings.indexOf(this) + 1] ?? null;
	}
}

interface Page {
	doc: { hidden: boolean };
	/** Delivers a MutationObserver batch. */
	mutate(records: { target: unknown; addedNodes: unknown[] }[]): void;
	/** Runs the pending timers. */
	tick(): void;
	dispatch(type: string): void;
}

/**
 * Runs the script in an example.com frame with `selectors`, `query` answering every querySelectorAll;
 * `ancestorOrigins` makes it a subframe (the last entry is the top document).
 */
function run(
	selectors: string[] | Record<string, string[]>,
	query: (css: string) => unknown[],
	allowlist: string[] = [],
	ancestorOrigins?: Record<string | number, unknown>,
	styleSheets: unknown[] = []
): Page {
	const { index, groups, entries } = keyedTable(Array.isArray(selectors) ? { "example.com": selectors } : selectors);
	const src = source
		.replace("__LILO_PROCEDURAL_INDEX__", JSON.stringify(index))
		.replace("__LILO_PROCEDURAL_GROUPS__", JSON.stringify(groups))
		.replace("__LILO_PROCEDURAL_TABLE__", JSON.stringify(entries))
		.replace("__LILO_ALLOWLIST__", JSON.stringify(`|${allowlist.join("|")}|`));
	const listeners: Record<string, () => void> = {};
	const doc = {
		readyState: "complete",
		hidden: false,
		documentElement: {},
		styleSheets,
		querySelectorAll: query,
		addEventListener: (type: string, cb: () => void) => {
			listeners[type] = cb;
		}
	};
	let observer: (records: unknown[]) => void = () => {};
	class FakeMutationObserver {
		constructor(cb: (records: unknown[]) => void) {
			observer = cb;
		}
		observe() {}
	}
	let timers: (() => void)[] = [];
	const setTimeout = (cb: () => void) => timers.push(cb);
	const fn = new Function("location", "document", "MutationObserver", "setTimeout", src);
	fn({ hostname: "example.com", host: "example.com", pathname: "/news/1", search: "?a=1", ancestorOrigins }, doc, FakeMutationObserver, setTimeout);
	return {
		doc,
		mutate: (records) => observer(records),
		tick: () => {
			const due = timers;
			timers = [];
			for (const cb of due) cb();
		},
		dispatch: (type) => listeners[type]?.()
	};
}

describe("procedural cosmetics", () => {
	test("an operator filters the elements its selector matches", () => {
		const ad = el("Sponsored post");
		const post = el("Regular post");
		run([".post:has-text(Sponsored)"], (css) => (css === ".post" ? [ad, post] : []));
		assert.equal(ad.style.hidden, true);
		assert.equal(post.style.hidden, false);
	});

	test("an exception on the host or its entity drops the selector there", () => {
		const ad = el("Ad");
		const side = el("Ad");
		run(
			{ "example.*": [".post:has-text(Ad)"], "example.com": [".post:has-text(Ad)", ".side:has-text(Ad)", "@.post:has-text(Ad)"] },
			(css) => (css === ".post" ? [ad] : css === ".side" ? [side] : [])
		);
		assert.equal(ad.style.hidden, false);
		assert.equal(side.style.hidden, true);
	});

	test("plain CSS after an operator skips the rule instead of hiding the ancestor", () => {
		const container = el("Ad");
		run(["div:has-text(Ad) > span"], (css) => (css === "div" ? [container] : []));
		assert.equal(container.style.hidden, false);
	});

	test("a frame goes by its top document for the allowlist", () => {
		const underAllowlisted = el("Sponsored post");
		run([".post:has-text(Sponsored)"], (css) => (css === ".post" ? [underAllowlisted] : []), ["allowed.example"], {
			length: 2,
			0: "https://mid.example",
			1: "https://www.allowed.example"
		});
		assert.equal(underAllowlisted.style.hidden, false);

		const allowlistedParentOnly = el("Sponsored post");
		run([".post:has-text(Sponsored)"], (css) => (css === ".post" ? [allowlistedParentOnly] : []), ["allowed.example"], {
			length: 2,
			0: "https://www.allowed.example",
			1: "https://news.example"
		});
		assert.equal(allowlistedParentOnly.style.hidden, true);
	});

	test("an insertion evaluates only the added subtree and its ancestors", () => {
		const html = new FakeNode("html");
		const feed = html.append(new FakeNode("feed"));
		const old = feed.append(new FakeNode("post", "Regular"));
		let documentQueries = 0;
		const page = run([".post:has-text(Sponsored)"], (css) => {
			documentQueries++;
			return html.querySelectorAll(css);
		});
		assert.equal(documentQueries, 1);

		const ad = feed.append(new FakeNode("post", "Sponsored"));
		// Changed without a record of its own: a scoped pass leaves it alone.
		old.text = "Sponsored";
		page.mutate([{ target: feed, addedNodes: [ad] }]);
		page.tick();
		assert.equal(ad.style.hidden, true);
		assert.equal(old.style.hidden, false);
		assert.equal(documentQueries, 1);
	});

	test("text inserted into an element re-evaluates the elements around it", () => {
		const html = new FakeNode("html");
		const post = html.append(new FakeNode("post"));
		const label = post.append(new FakeNode("label", "Regular"));
		const page = run([".post:has-text(Sponsored)"], (css) => html.querySelectorAll(css));
		assert.equal(post.style.hidden, false);

		label.text = "Sponsored";
		page.mutate([{ target: label, addedNodes: [{ nodeType: 3 }] }]);
		page.tick();
		assert.equal(post.style.hidden, true);
	});

	test("an element's text is read once per pass", () => {
		const html = new FakeNode("html");
		const post = html.append(new FakeNode("post", "Sponsored"));
		run([".post:has-text(Promoted)", ".post:has-text(Sponsored)"], (css) => html.querySelectorAll(css));
		assert.equal(post.style.hidden, true);
		assert.equal(post.textReads, 1);
	});

	test("insertions in a hidden page wait for a full pass once visible", () => {
		const html = new FakeNode("html");
		let documentQueries = 0;
		const page = run([".post:has-text(Sponsored)"], (css) => {
			documentQueries++;
			return html.querySelectorAll(css);
		});
		page.doc.hidden = true;
		const ad = html.append(new FakeNode("post", "Sponsored"));
		page.mutate([{ target: html, addedNodes: [ad] }]);
		page.tick();
		assert.equal(ad.style.hidden, false);

		page.doc.hidden = false;
		page.dispatch("visibilitychange");
		assert.equal(ad.style.hidden, true);
		assert.equal(documentQueries, 2);
	});

	test("a leading :matches-path() conditions the selector on the page's path", () => {
		const news = new FakeNode("ad"), sport = new FakeNode("promo");
		run([":matches-path(/news) .ad", ":matches-path(/^\\/sport/) .promo"], (css) => (css === ".ad" ? [news] : css === ".promo" ? [sport] : []));
		assert.equal(news.style.hidden, true);
		assert.equal(sport.style.hidden, false);
	});

	test(":remove-attr() and :remove-class() strip what they name, and :matches-attr() filters", () => {
		const element = (attrs: Record<string, string>, classes: string[]) => {
			const el = {
				nodeType: 1,
				attrs: { ...attrs },
				classes: [...classes],
				get attributes() { return Object.entries(el.attrs).map(([name, value]) => ({ name, value })); },
				removeAttribute(name: string) { delete el.attrs[name]; },
				get classList() {
					return Object.assign([...el.classes], { remove: (name: string) => { el.classes = el.classes.filter((c) => c !== name); } });
				}
			};
			return el;
		};
		const link = element({ onclick: "track()", "data-ad": "1", href: "/x" }, ["link", "ad-badge", "ad-x"]);
		const plain = element({ href: "/y" }, ["link"]);
		run(
			["a:matches-attr(\"data-ad\"=\"1\"):remove-attr(/^on|^data-/)", "a:remove-class(/^ad-/)"],
			(css) => (css === "a" ? [link, plain] : [])
		);
		assert.deepEqual(link.attrs, { href: "/x" });
		assert.deepEqual(link.classes, ["link"]);
		assert.deepEqual(plain.attrs, { href: "/y" });
	});

	test(":matches-attr() leaves the elements without the attribute alone", () => {
		const element = (attrs: Record<string, string>) => ({ ...el(""), attributes: Object.entries(attrs).map(([name, value]) => ({ name, value })) });
		const ad = element({ "data-ad": "1" });
		const plain = element({ href: "/x" });
		run(["a:matches-attr(data-ad)"], (css) => (css === "a" ? [ad, plain] : []));
		assert.equal(ad.style.hidden, true);
		assert.equal(plain.style.hidden, false);
	});

	test("a :has() or :not() of a procedural selector evaluates it in each element", () => {
		const html = new FakeNode("html");
		const sponsored = html.append(new FakeNode("card"));
		sponsored.append(new FakeNode("label", "Sponsored"));
		const regular = html.append(new FakeNode("card"));
		regular.append(new FakeNode("label", "News"));
		const kept = html.append(new FakeNode("tile"));
		kept.append(new FakeNode("label", "Sponsored"));
		const shown = html.append(new FakeNode("tile"));
		shown.append(new FakeNode("label", "News"));
		run([".card:has(.label:has-text(Sponsored))", ".tile:not(:has-text(Sponsored))"], (css) => html.querySelectorAll(css));
		assert.deepEqual([sponsored.style.hidden, regular.style.hidden], [true, false]);
		assert.deepEqual([kept.style.hidden, shown.style.hidden], [false, true]);
	});

	test("a leading :not(:matches-path()) conditions the selector on another path", () => {
		const ad = new FakeNode("ad");
		const promo = new FakeNode("promo");
		run([":not(:matches-path(/news)) .ad", ":not(:matches-path(/sport)) .promo"], (css) => (css === ".ad" ? [ad] : css === ".promo" ? [promo] : []));
		assert.equal(ad.style.hidden, false);
		assert.equal(promo.style.hidden, true);
	});

	test(":others() hides all but its subjects, their ancestors and descendants, and shows again what holds a later subject", () => {
		const html = new FakeNode("html");
		const body = html.append(new FakeNode("body"));
		const main = body.append(new FakeNode("main"));
		const link = main.append(new FakeNode("link"));
		const inside = link.append(new FakeNode("icon"));
		const nested = inside.append(new FakeNode("link"));
		const besideNested = inside.append(new FakeNode("label"));
		const sidebar = main.append(new FakeNode("sidebar"));
		const footer = body.append(new FakeNode("footer"));
		const page = run([".link:others()"], (css) => html.querySelectorAll(css));
		assert.deepEqual([body, main, link, inside, nested, besideNested].map((n) => n.style.hidden), [false, false, false, false, false, false]);
		assert.deepEqual([sidebar.style.hidden, footer.style.hidden], [true, true]);

		const late = footer.append(new FakeNode("link"));
		page.mutate([{ target: footer, addedNodes: [late] }]);
		page.tick();
		assert.equal(footer.style.hidden, false);
		assert.equal(sidebar.style.hidden, true);
	});

	test(":-abp-properties() selects what the matching style rules select", () => {
		const banner = new FakeNode("banner");
		const badge = new FakeNode("badge");
		const style = (declarations: Record<string, string>) =>
			Object.assign(Object.keys(declarations), {
				getPropertyValue: (name: string) => declarations[name],
				getPropertyPriority: () => ""
			});
		const sheets = [
			{ cssRules: [{ type: 1, selectorText: ".banner", style: style({ width: "300px", height: "250px" }) }] },
			{ cssRules: [{ type: 1, selectorText: ".badge::before", style: style({ content: '"Ad"' }) }] },
			{
				get cssRules(): unknown[] {
					throw new Error("SecurityError");
				}
			}
		];
		const query = (css: string) => (css === ".banner" ? [banner] : css === ".banner, .badge" ? [banner, badge] : []);
		run([":-abp-properties(WIDTH: 3*px; height:250px;)"], query, [], undefined, sheets);
		assert.deepEqual([banner.style.hidden, badge.style.hidden], [true, false]);
		run([":-abp-properties(/content: \"Ad\"|height: 250px/)"], query, [], undefined, sheets);
		assert.equal(badge.style.hidden, true);
	});
});
