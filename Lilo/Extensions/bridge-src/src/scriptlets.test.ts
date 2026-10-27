// Tests for the page-injected scriptlet runtime (Scriptlets.js), around its response rewriting.
import { test, describe, beforeEach, afterEach, mock } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { keyHash, keyedTable } from "./filterTables.testkit.ts";

const source = readFileSync(new URL("../../../ContentBlocker/Scriptlets.js", import.meta.url), "utf8");

class FakeResponse {
	static cloneCount = 0;
	body: string;
	status = 200;
	statusText = "OK";
	headers: Record<string, string> = {};

	constructor(body: string) {
		this.body = body;
	}

	clone(): FakeResponse {
		FakeResponse.cloneCount++;
		return new FakeResponse(this.body);
	}

	text(): Promise<string> {
		return Promise.resolve(this.body);
	}

	json(): Promise<unknown> {
		return Promise.resolve(JSON.parse(this.body));
	}
}

// The runtime wraps these shared natives; each test starts from the unwrapped ones.
const fakeResponseJSON = FakeResponse.prototype.json;
const functionToString = Function.prototype.toString;

interface FakeXHRStatics {
	instances: FakeXHRInstance[];
}

interface FakeXHRInstance {
	readyState: number;
	responseType: string;
	responseText: string;
	responseTextReads: number;
	listeners: (() => void)[];
	open(method: string, url: string): void;
	addEventListener(type: string, cb: () => void): void;
	finish(body: string): void;
}

function makeFakeXHR(): (new () => FakeXHRInstance) & FakeXHRStatics {
	class FakeXHR {
		static instances: FakeXHRInstance[] = [];
		readyState = 0;
		responseType = "";
		responseTextReads = 0;
		listeners: (() => void)[] = [];
		#body = "";

		constructor() {
			FakeXHR.instances.push(this);
		}

		get responseText(): string {
			this.responseTextReads++;
			return this.#body;
		}

		open(_method: string, _url: string): void {}

		addEventListener(_type: string, cb: () => void): void {
			this.listeners.push(cb);
		}

		finish(body: string): void {
			this.#body = body;
			this.readyState = 4;
			for (const cb of [...this.listeners]) cb();
		}
	}
	return FakeXHR;
}

interface Sandbox {
	self: { fetch: (input: unknown) => Promise<FakeResponse>; open?: unknown } & Record<string, unknown>;
	fetchCalls: string[];
	XHR: (new () => FakeXHRInstance) & FakeXHRStatics;
	json: { parse: (s: string) => unknown; stringify: (v: unknown) => string };
	location: { reloads: number };
}


function run(
	table: Record<string, unknown[]>,
	hostname: string,
	responseBody: string,
	allowlist: string[] = [],
	ancestorOrigins?: Record<string | number, unknown>,
	globals: Record<string, unknown> = {}
): Sandbox {
	const fetchCalls: string[] = [];
	const XHR = makeFakeXHR();
	const json = { parse: JSON.parse.bind(JSON), stringify: JSON.stringify.bind(JSON) };
	// The runtime resolves fetch and XMLHttpRequest through `self`, as in a real page.
	const self: Sandbox["self"] = {
		fetch: (input: unknown) => {
			fetchCalls.push(String(input));
			return Promise.resolve(new FakeResponse(responseBody));
		},
		XMLHttpRequest: XHR,
		...globals
	};
	// A scriptlet entry is its name's base-36 index into the names and its args, joined by \xa6; an exception keeps its `@`.
	const names: string[] = [];
	const ref = (name: string) => {
		const bare = name.replace(/^@/, "");
		if (bare && !names.includes(bare)) names.push(bare);
		return (name[0] === "@" ? "@" : "") + (bare ? names.indexOf(bare).toString(36) : "");
	};
	const flat = Object.fromEntries(
		Object.entries(table).map(([host, list]) => [host, (list as [string, string[]][]).map(([name, args]) => [ref(name), ...args].join("\xa6"))])
	);
	const { index, groups, entries } = keyedTable(flat);
	const src = source
		.replace("__LILO_SCRIPTLET_INDEX__", JSON.stringify(index))
		.replace("__LILO_SCRIPTLET_GROUPS__", JSON.stringify(groups))
		.replace("__LILO_SCRIPTLET_TABLE__", JSON.stringify(entries))
		.replace("__LILO_SCRIPTLET_NAMES__", JSON.stringify(names.join(" ")))
		.replace("__LILO_ALLOWLIST__", JSON.stringify(`|${allowlist.join("|")}|`));
	const fn = new Function("self", "location", "Response", "XMLHttpRequest", "JSON", src);
	const location = { hostname, host: hostname, ancestorOrigins, reloads: 0, reload: () => location.reloads++ };
	fn(self, location, FakeResponse, XHR, json);
	return { self, fetchCalls, XHR, json, location };
}

beforeEach(() => {
	FakeResponse.cloneCount = 0;
	FakeResponse.prototype.json = fakeResponseJSON;
	Function.prototype.toString = functionToString;
});

describe("fetch response rewriting", () => {
	const HOST = "www.youtube.com";

	test("a host the table does not list is left alone", async () => {
		const sandbox = run(
			{ "somewhere-else.example": [["trusted-replace-fetch-response", ['"adPlacements"', '"no_ads"', "player?"]]] },
			HOST,
			'{"adPlacements":[1],"x":2}'
		);
		const resp = await sandbox.self.fetch("https://www.youtube.com/youtubei/v1/player?key=1");
		assert.equal(await resp.text(), '{"adPlacements":[1],"x":2}');
	});

	test("an allowlisted site is left alone", async () => {
		const sandbox = run(
			{ [HOST]: [["trusted-replace-fetch-response", ['"adPlacements"', '"no_ads"', "player?"]]] },
			HOST,
			'{"adPlacements":[1],"x":2}',
			["youtube.com"]
		);
		const resp = await sandbox.self.fetch("https://www.youtube.com/youtubei/v1/player?key=1");
		assert.equal(await resp.text(), '{"adPlacements":[1],"x":2}');
	});

	test("a frame goes by its top document for the allowlist", async () => {
		const table = { "ads.example": [["trusted-replace-fetch-response", ['"adPlacements"', '"no_ads"', "player?"]]] };
		const body = '{"adPlacements":[1],"x":2}';
		const url = "https://ads.example/player?key=1";

		const underAllowlisted = run(table, "ads.example", body, ["allowed.example"], {
			length: 2,
			0: "https://mid.example",
			1: "https://www.allowed.example"
		});
		assert.equal(await (await underAllowlisted.self.fetch(url)).text(), body);

		const underOther = run(table, "ads.example", body, ["allowed.example"], {
			length: 2,
			0: "https://www.allowed.example",
			1: "https://news.example"
		});
		assert.equal(await (await underOther.self.fetch(url)).text(), '{"no_ads":[1],"x":2}');
	});

	test("a matching text replacement rewrites the body", async () => {
		const sandbox = run(
			{ [HOST]: [["trusted-replace-fetch-response", ['"adPlacements"', '"no_ads"', "player?"]]] },
			HOST,
			'{"adPlacements":[1],"x":2}'
		);
		const resp = await sandbox.self.fetch("https://www.youtube.com/youtubei/v1/player?key=1");
		assert.equal(await resp.text(), '{"no_ads":[1],"x":2}');
	});

	test("a non-matching URL passes the original response through", async () => {
		const original: FakeResponse[] = [];
		const sandbox = run(
			{ [HOST]: [["trusted-replace-fetch-response", ['"adPlacements"', '"no_ads"', "player?"]]] },
			HOST,
			'{"adPlacements":[1]}'
		);
		const native = sandbox.self.fetch;
		// Capture what the native layer produced to compare identity.
		const resp = await native("https://www.youtube.com/watch");
		original.push(resp);
		assert.equal(resp.body, '{"adPlacements":[1]}');
	});

	test("an untouched body passes the original response object through", async () => {
		// Whitespace forces a JSON.parse/stringify round-trip difference: only an actual prune
		// may produce a new Response, re-serialization alone must not.
		const sandbox = run(
			{ [HOST]: [["json-prune-fetch-response", ["adPlacements adSlots", "", "propsToMatch", "/player?"]]] },
			HOST,
			'{"a": 1}'
		);
		const p = sandbox.self.fetch("https://www.youtube.com/youtubei/v1/player?key=1");
		const resp = await p;
		// The whitespace survives: proof the body was not re-serialized. One clone to inspect it.
		assert.equal(resp.body, '{"a": 1}');
		assert.equal(FakeResponse.cloneCount, 1);
	});

	test("a Request goes by its real URL, not the url property the page set on it", async () => {
		// YouTube's canary: a data: URL Request dressed as a /player call, its body checked for tampering.
		const body = '{"adPlacements":true,"playerAds":true}';
		const sandbox = run({ [HOST]: [["json-prune-fetch-response", ["adPlacements", "", "propsToMatch", "/player?"]]] }, HOST, body);
		const fetch = sandbox.self.fetch as (input: Request) => Promise<FakeResponse>;
		const canary = new Request(`data:application/json,${body}`);
		Object.defineProperty(canary, "url", { value: "https://www.youtube.com/youtubei/v1/player?key=1" });
		assert.equal(await (await fetch(canary)).text(), body);
		const real = await fetch(new Request("https://www.youtube.com/youtubei/v1/player?key=1", { method: "POST" }));
		assert.deepEqual(sandbox.json.parse(await real.text()), { playerAds: true });
	});

	test("stacked rewriters read the body once", async () => {
		const sandbox = run(
			{
				[HOST]: [
					["trusted-replace-fetch-response", ['"adPlacements"', '"no_ads"', "player?"]],
					["trusted-replace-fetch-response", ['"adSlots"', '"no_slots"', "player?"]],
					["json-prune-fetch-response", ["playerAds", "", "propsToMatch", "/player?"]]
				]
			},
			HOST,
			'{"adPlacements":1,"adSlots":2,"playerAds":3,"keep":4}'
		);
		const resp = await sandbox.self.fetch("https://www.youtube.com/youtubei/v1/player?key=1");
		assert.equal(FakeResponse.cloneCount, 1);
		assert.equal(sandbox.fetchCalls.length, 1);
		const out = sandbox.json.parse(await resp.text()) as Record<string, unknown>;
		assert.deepEqual(out, { no_ads: 1, no_slots: 2, keep: 4 });
	});
});

describe("xhr response rewriting", () => {
	const HOST = "www.youtube.com";

	test("stacked rewriters apply in one pass over one body read", () => {
		const sandbox = run(
			{
				[HOST]: [
					["trusted-replace-xhr-response", ['"adPlacements"', '"no_ads"', "/player?"]],
					["json-prune-xhr-response", ["adSlots", "", "propsToMatch", "/player?"]]
				]
			},
			HOST,
			""
		);
		const xhr = new sandbox.XHR();
		xhr.open("GET", "https://www.youtube.com/youtubei/v1/player?key=1");
		xhr.finish('{"adPlacements":1,"adSlots":2,"keep":3}');
		assert.deepEqual(sandbox.json.parse(xhr.responseText), { no_ads: 1, keep: 3 });
		// The native body is read once; later reads hit the redefined instance getter.
		assert.equal(xhr.responseTextReads, 1);
	});

	test("a listener added before open reads the rewritten body too", () => {
		const sandbox = run({ [HOST]: [["json-prune-xhr-response", ["adPlacements", "", "propsToMatch", "/player?"]]] }, HOST, "");
		const xhr = new sandbox.XHR();
		let seen = "";
		xhr.addEventListener("readystatechange", () => (seen = xhr.responseText));
		xhr.open("GET", "https://www.youtube.com/youtubei/v1/player?key=1");
		xhr.finish('{"adPlacements":1,"keep":3}');
		assert.deepEqual(sandbox.json.parse(seen), { keep: 3 });
	});

	test("an untouched xhr body keeps its native getters", () => {
		const sandbox = run(
			{ [HOST]: [["json-prune-xhr-response", ["absent", "", "propsToMatch", "/player?"]]] },
			HOST,
			""
		);
		const xhr = new sandbox.XHR();
		xhr.open("GET", "https://www.youtube.com/youtubei/v1/player?key=1");
		xhr.finish('{"a": 1}');
		assert.equal(xhr.responseText, '{"a": 1}');
	});
});

describe("json-prune", () => {
	test("multiple prune entries apply through a single JSON.parse hook", () => {
		const HOST = "www.youtube.com";
		const sandbox = run(
			{
				[HOST]: [
					["json-prune", ["ytInitialPlayerResponse.adPlacements"]],
					["json-prune", ["ytInitialPlayerResponse.adSlots"]]
				]
			},
			HOST,
			""
		);
		const parsed = sandbox.json.parse(
			'{"ytInitialPlayerResponse":{"adPlacements":1,"adSlots":2,"videoDetails":3}}'
		) as Record<string, Record<string, unknown>>;
		assert.deepEqual(parsed.ytInitialPlayerResponse, { videoDetails: 3 });
	});

	test("[-] removes the array items the rest of the path matches in", () => {
		const HOST = "www.youtube.com";
		const sandbox = run({ [HOST]: [["json-prune", ["entries.[-].command.adClientParams.isAd"]]] }, HOST, "");
		const parsed = sandbox.json.parse(
			'{"entries":[{"command":{"adClientParams":{"isAd":true}}},{"command":{"videoId":"v"}}]}'
		) as Record<string, unknown>;
		assert.deepEqual(parsed, { entries: [{ command: { videoId: "v" } }] });
	});

	test("prunes what Response.json() resolves to", async () => {
		run({ "m.youtube.com": [["json-prune", ["playerAds adPlacements"]]] }, "m.youtube.com", "");
		const parsed = await new FakeResponse('{"playerAds":1,"adPlacements":2,"videoDetails":3}').json();
		assert.deepEqual(parsed, { videoDetails: 3 });
	});
});

describe("YouTube request scriptlets", () => {
	const HOST = "www.youtube.com";

	test("trusted-edit-inbound-object edits a copy of a matching object, and passes others through", () => {
		const json = { parse: JSON.parse.bind(JSON), stringify: JSON.stringify.bind(JSON) };
		const filter = '[?.attestationRequest][?.context.client.userAgent*="channel"]';
		run(
			{
				[HOST]: [
					["trusted-edit-inbound-object", ["JSON.stringify", "0", `${filter}.context.client[?.clientName=="WEB"]+={"clientScreen":"CHANNEL"}`]],
					["trusted-edit-inbound-object", ["JSON.stringify", "0", `${filter}.playbackContext.contentPlaybackContext.lactMilliseconds="\${now}"`]],
					[
						"trusted-edit-inbound-object",
						["JSON.stringify", "0", '[?.attestationRequest][?.context.client.userAgent=/adunit|channel/].playbackContext.contentPlaybackContext.referer=repl({"regex":"(?:#reloadxhr)?$","replacement":"#reloadxhr"})']
					]
				]
			},
			HOST,
			"",
			[],
			undefined,
			{ JSON: json }
		);
		const request = {
			context: { client: { clientName: "WEB", userAgent: "Mozilla/5.0 (Macintosh; channel)" } },
			attestationRequest: {},
			playbackContext: { contentPlaybackContext: { lactMilliseconds: "-1", referer: "https://www.youtube.com/" } }
		};
		const sent = JSON.parse(json.stringify(request));
		assert.equal(sent.context.client.clientScreen, "CHANNEL");
		assert.match(sent.playbackContext.contentPlaybackContext.lactMilliseconds, /^\d{10,}$/);
		assert.equal(sent.playbackContext.contentPlaybackContext.referer, "https://www.youtube.com/#reloadxhr");
		assert.equal(request.playbackContext.contentPlaybackContext.lactMilliseconds, "-1");

		const other = { context: { client: { clientName: "WEB", userAgent: "channel" } } };
		assert.equal(json.stringify(other), JSON.stringify(other));
	});

	test("adjust-setTimeout scales only matching timers", () => {
		const delays: number[] = [];
		const sandbox = run({ [HOST]: [["adjust-setTimeout", ["[native code]", "17000", "0.001"]]] }, HOST, "", [], undefined, {
			setTimeout: (_cb: unknown, delay: number) => delays.push(delay)
		});
		const setTimeout = sandbox.self.setTimeout as (cb: unknown, delay: number) => void;
		setTimeout(Math.max, 17000);
		setTimeout(() => {}, 17000);
		setTimeout(Math.max, 1000);
		assert.deepEqual(delays, [17, 17000, 1000]);
	});

	test("trusted-prevent-dom-bypass hands an inserted blank frame the page's own methods, one per rule", () => {
		const Node = { prototype: { appendChild: (el: unknown) => el } };
		const rules = [["trusted-prevent-dom-bypass", ["Node.prototype.appendChild", "fetch"]], ["trusted-prevent-dom-bypass", ["Node.prototype.appendChild", "Request"]]];
		const sandbox = run({ [HOST]: rules }, HOST, "", [], undefined, { Node });
		const frame = (href: string) => ({
			contentWindow: { fetch: "pristine", Request: "pristine", location: { href }, toString: () => "[object Window]" }
		});
		const blank = frame("about:blank");
		const elsewhere = frame("https://other.example/");
		Node.prototype.appendChild(blank);
		Node.prototype.appendChild(elsewhere);
		assert.equal(blank.contentWindow.fetch, sandbox.self.fetch);
		assert.equal(blank.contentWindow.Request, sandbox.self.Request);
		assert.equal(elsewhere.contentWindow.fetch, "pristine");
	});
});

describe("JSONPath and request scriptlets", () => {
	const HOST = "www.example.com";

	test("json-edit removes matches at any depth, splicing array elements out", () => {
		const json = { parse: JSON.parse.bind(JSON), stringify: JSON.stringify.bind(JSON) };
		run(
			{ [HOST]: [["json-edit", ['..feed.*[?.type=="ad"]']], ["json-edit", ["..tracking"]], ["json-edit", ['.x="y"']]] },
			HOST,
			"",
			[],
			undefined,
			{ JSON: json }
		);
		const parsed = json.parse(
			'{"page":{"feed":[{"type":"post","id":1},{"type":"ad"},{"type":"ad"},{"type":"post","id":2}]},"a":{"b":{"tracking":1}},"x":1}'
		);
		assert.deepEqual(parsed, { page: { feed: [{ type: "post", id: 1 }, { type: "post", id: 2 }] }, a: { b: {} }, x: 1 });
	});

	test("jsonl-edit-xhr-response edits each JSON line of the matching response", () => {
		const sandbox = run(
			{ [HOST]: [["jsonl-edit-xhr-response", ['..node[?.__typename=="Ad"]', "propsToMatch", "/graphql"]]] },
			HOST,
			""
		);
		const body = ['{"data":{"node":{"__typename":"Ad"}}}', "not json", '{"data":{"node":{"__typename":"Post"}}}'].join("\n");
		const xhr = new sandbox.XHR();
		xhr.open("POST", "https://www.example.com/api/graphql");
		xhr.finish(body);
		assert.deepEqual(xhr.responseText.split("\n"), ['{"data":{}}', "not json", '{"data":{"node":{"__typename":"Post"}}}']);
		const other = new sandbox.XHR();
		other.open("POST", "https://www.example.com/api/other");
		other.finish(body);
		assert.equal(other.responseText, body);
	});

	test("json-edit-fetch-response edits the matching response", async () => {
		const sandbox = run(
			{ [HOST]: [["json-edit-fetch-response", [".items.*[?.sponsored==true]", "propsToMatch", "/feed"]]] },
			HOST,
			'{"items":[{"id":1},{"id":2,"sponsored":true}]}'
		);
		assert.equal(await (await sandbox.self.fetch("https://www.example.com/feed")).text(), '{"items":[{"id":1}]}');
		assert.equal(
			await (await sandbox.self.fetch("https://www.example.com/other")).text(),
			'{"items":[{"id":1},{"id":2,"sponsored":true}]}'
		);
	});

	test("no-xhr-if never sends a matching request and completes it as a 200", async () => {
		const sent: string[] = [];
		class XHR extends EventTarget {
			url = "";
			responseType = "";
			open(_method: string, url: string) {
				this.url = url;
			}
			send() {
				sent.push(this.url);
			}
		}
		const sandbox = run({ [HOST]: [["no-xhr-if", ["googlesyndication", "emptyObj"]]] }, HOST, "", [], undefined, {
			XMLHttpRequest: XHR
		});
		const Ctor = sandbox.self.XMLHttpRequest as typeof XHR;
		const blocked = new Ctor() as XHR & { status?: number; responseText?: string; readyState?: number };
		const events: string[] = [];
		for (const type of ["readystatechange", "load", "loadend"]) blocked.addEventListener(type, () => events.push(type));
		blocked.open("GET", "https://pagead2.googlesyndication.com/ads.js");
		blocked.send();
		const passed = new Ctor();
		passed.open("GET", "https://www.example.com/api");
		passed.send();
		await Promise.resolve();
		assert.deepEqual(sent, ["https://www.example.com/api"]);
		assert.deepEqual(events, ["readystatechange", "load", "loadend"]);
		assert.equal(blocked.status, 200);
		assert.equal(blocked.readyState, 4);
		assert.equal(blocked.responseText, "{}");
	});

	test("a method: part of propsToMatch matches the request method, with every other part", async () => {
		const sent: string[] = [];
		class XHR extends EventTarget {
			responseType = "";
			method = "";
			open(method: string) {
				this.method = method;
			}
			send() {
				sent.push(this.method);
			}
		}
		const sandbox = run(
			{ [HOST]: [["no-fetch-if", ["/track method:POST"]], ["no-xhr-if", ["method:/^POST$/"]]] },
			HOST,
			"",
			[],
			undefined,
			{ XMLHttpRequest: XHR }
		);
		const fetch = sandbox.self.fetch as (input: unknown, init?: { method: string }) => Promise<FakeResponse>;
		await fetch("https://www.example.com/track", { method: "post" });
		await fetch("https://www.example.com/track");
		await fetch("https://www.example.com/other", { method: "POST" });
		assert.deepEqual(sandbox.fetchCalls, ["https://www.example.com/track", "https://www.example.com/other"]);
		const Ctor = sandbox.self.XMLHttpRequest as typeof XHR;
		for (const method of ["POST", "GET"]) {
			const xhr = new Ctor();
			xhr.open(method);
			xhr.send();
		}
		assert.deepEqual(sent, ["GET"]);
	});

	test("the fetch, JSON.parse and XHR open wrappers print as the functions they wrap", () => {
		const sandbox = run(
			{
				[HOST]: [
					["json-prune", ["ads"]],
					["json-prune-fetch-response", ["ads", "", "propsToMatch", "/feed"]],
					["no-fetch-if", ["/ads.js"]],
					["json-prune-xhr-response", ["ads", "", "propsToMatch", "/feed"]]
				]
			},
			HOST,
			""
		);
		const print = (fn: unknown) => Function.prototype.toString.call(fn);
		assert.match(print(sandbox.self.fetch), /fetchCalls\.push/);
		assert.equal(String(sandbox.self.fetch), print(sandbox.self.fetch));
		assert.equal(print(sandbox.json.parse), print(JSON.parse.bind(JSON)));
		assert.equal(print(sandbox.XHR.prototype.open), print(makeFakeXHR().prototype.open));
		assert.equal(print(Function.prototype.toString), print(functionToString));
	});

	test("noeval-if drops matching code only", () => {
		const evaluated: string[] = [];
		const sandbox = run({ [HOST]: [["noeval-if", ["adblock"]]] }, HOST, "", [], undefined, {
			eval: (code: string) => evaluated.push(code)
		});
		const evalFn = sandbox.self.eval as (code: string) => void;
		evalFn("detect_adblock()");
		evalFn("render()");
		assert.deepEqual(evaluated, ["render()"]);
	});

	test("trusted-replace-argument rewrites the argument under its condition", () => {
		const calls: unknown[] = [];
		const api = { track: (a: unknown, b: unknown) => calls.push([a, b]) };
		run(
			{
				[HOST]: [
					["trusted-replace-argument", ["api.track", "1", "repl:/ads=1/ads=0/", "condition", "ads="]],
					["trusted-replace-argument", ["api.track", "0", "false", "condition", "/^show/"]]
				]
			},
			HOST,
			"",
			[],
			undefined,
			{ api }
		);
		api.track("showBanner", "x&ads=1");
		api.track("other", "y");
		assert.deepEqual(calls, [[false, "x&ads=0"], ["other", "y"]]);
	});
});

describe("more scriptlets", () => {
	const HOST = "www.example.com";

	test("trusted-set-constant takes JSON, edit-object-on-setter edits what the page assigns", () => {
		const document = { visibilityState: "hidden" };
		const sandbox = run(
			{
				[HOST]: [
					["trusted-set-constant", ["document.visibilityState", 'json:"visible"']],
					["edit-object-on-setter", ["playerConfig", ".ads"]]
				]
			},
			HOST,
			"",
			[],
			undefined,
			{ document }
		);
		assert.equal(document.visibilityState, "visible");
		sandbox.self.playerConfig = { ads: [1], video: "x" };
		assert.deepEqual(sandbox.self.playerConfig, { video: "x" });
	});

	test("set-constant chains through one property all apply", () => {
		const sandbox = run(
			{
				[HOST]: [
					["set-constant", ["ytInitialPlayerResponse.playerAds", "undefined"]],
					["set-constant", ["ytInitialPlayerResponse.adPlacements", "undefined"]],
					["set-constant", ["ytInitialPlayerResponse.adSlots", "undefined"]]
				]
			},
			HOST,
			""
		);
		sandbox.self.ytInitialPlayerResponse = { playerAds: 1, adPlacements: 2, adSlots: 3, videoDetails: 4 };
		const response = sandbox.self.ytInitialPlayerResponse as Record<string, unknown>;
		assert.deepEqual([response.playerAds, response.adPlacements, response.adSlots, response.videoDetails], [undefined, undefined, undefined, 4]);
	});

	test("abort-on-property-read chains through one property all apply", () => {
		const sandbox = run(
			{ [HOST]: [["abort-on-property-read", ["ads.config"]], ["abort-on-property-read", ["ads.slots"]]] },
			HOST,
			""
		);
		sandbox.self.ads = { config: 1, slots: 2, keep: 3 };
		const ads = sandbox.self.ads as Record<string, unknown>;
		assert.throws(() => ads.config, ReferenceError);
		assert.throws(() => ads.slots, ReferenceError);
		assert.equal(ads.keep, 3);
	});

	test("abort-on-property-write chains through one property all apply", () => {
		const sandbox = run(
			{ [HOST]: [["abort-on-property-write", ["ads.config"]], ["abort-on-property-write", ["ads.slots"]]] },
			HOST,
			""
		);
		sandbox.self.ads = {};
		const ads = sandbox.self.ads as Record<string, unknown>;
		assert.throws(() => (ads.config = 1), ReferenceError);
		assert.throws(() => (ads.slots = 2), ReferenceError);
		ads.keep = 3;
		assert.equal(ads.keep, 3);
	});

	test("abort-current-script rules on one property all apply", () => {
		class HTMLScriptElement {
			src = "";
			textContent: string;
			constructor(textContent: string) {
				this.textContent = textContent;
			}
		}
		const g = globalThis as Record<string, unknown>;
		g.HTMLScriptElement = HTMLScriptElement;
		g.document = { currentScript: null };
		try {
			const sandbox = run(
				{ [HOST]: [["abort-current-script", ["probe", "first"]], ["abort-current-script", ["probe", "second"]]] },
				HOST,
				"",
				[],
				undefined,
				{ probe: 1 }
			);
			const readAs = (text: string) => {
				(g.document as { currentScript: unknown }).currentScript = new HTMLScriptElement(text);
				return sandbox.self.probe;
			};
			assert.throws(() => readAs("first()"), ReferenceError);
			assert.throws(() => readAs("second()"), ReferenceError);
			assert.equal(readAs("other()"), 1);

			// One verdict per rule and script: a hot property read again does not read the script's text again.
			let textReads = 0;
			const script = new HTMLScriptElement("first()");
			Object.defineProperty(script, "textContent", {
				get: () => {
					textReads++;
					return "first()";
				}
			});
			(g.document as { currentScript: unknown }).currentScript = script;
			for (let i = 0; i < 3; i++) assert.throws(() => sandbox.self.probe, ReferenceError);
			assert.equal(textReads, 2);
		} finally {
			delete g.HTMLScriptElement;
			delete g.document;
		}
	});

	test("edit-object-on-setter rules on one property all apply", () => {
		const sandbox = run(
			{ [HOST]: [["edit-object-on-setter", ["playerConfig", ".ads"]], ["edit-object-on-setter", ["playerConfig", ".tracking"]]] },
			HOST,
			""
		);
		sandbox.self.playerConfig = { ads: [1], tracking: 2, video: "x" };
		assert.deepEqual(sandbox.self.playerConfig, { video: "x" });
	});

	test("trusted-suppress-native-method prevents or aborts the matching calls only", () => {
		const created: string[] = [];
		const Document = { prototype: { createElement: (tag: string) => created.push(tag) } };
		run({ [HOST]: [["trusted-suppress-native-method", ["Document.prototype.createElement", '"script"', "prevent"]]] }, HOST, "", [], undefined, {
			Document
		});
		Document.prototype.createElement("script");
		Document.prototype.createElement("div");
		assert.deepEqual(created, ["div"]);
	});

	test("m3u-prune drops the matching segments of a playlist", async () => {
		const playlist = "#EXTM3U\n#EXTINF:5,\nmain1.ts\n#EXTINF:5,\nad-01.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:5,\nmain2.ts";
		const sandbox = run({ [HOST]: [["m3u-prune", ["/^ad-/", ".m3u8"]]] }, HOST, playlist);
		const body = await (await sandbox.self.fetch("https://cdn.example/live.m3u8")).text();
		assert.equal(body, "#EXTM3U\n#EXTINF:5,\nmain1.ts\n#EXTINF:5,\nmain2.ts");
	});

	test("prevent-innerHTML drops matching writes", () => {
		const writes: string[] = [];
		class Element {}
		Object.defineProperty(Element.prototype, "innerHTML", { configurable: true, get: () => "", set: (v: string) => writes.push(v) });
		run({ [HOST]: [["prevent-innerHTML", ["", "adblock"]]] }, HOST, "", [], undefined, { Element });
		const el = new Element() as { innerHTML: string };
		el.innerHTML = "<p>adblock detected</p>";
		el.innerHTML = "<p>hello</p>";
		assert.deepEqual(writes, ["<p>hello</p>"]);
	});

	test("fuckadblock-defuser reports no blocker on every global, and chains", () => {
		type Detector = {
			check(): Detector;
			emitEvent(): Detector;
			clearEvent(): Detector;
			setOption(key: string, value: unknown): Detector;
			onDetected(f: () => void): Detector;
			onNotDetected(f: () => void): Detector;
			on(detected: boolean, f: () => void): Detector;
		};
		const { self } = run({ [HOST]: [["fuckadblock-defuser", []]] }, HOST, "");
		for (const name of ["fuckAdBlock", "blockAdBlock"]) {
			const calls: string[] = [];
			const fab = self[name] as Detector;
			const chained = fab
				.setOption("checkOnLoad", true)
				.onDetected(() => calls.push("detected"))
				.onNotDetected(() => calls.push("clean"))
				.on(true, () => calls.push("detected"))
				.on(false, () => calls.push("clean"))
				.check()
				.emitEvent()
				.clearEvent();
			assert.equal(chained, fab, name);
			assert.deepEqual(calls, ["clean", "clean"], name);
		}
		for (const name of ["FuckAdBlock", "BlockAdBlock"]) {
			const Ctor = self[name] as new () => Detector;
			const calls: string[] = [];
			new Ctor().onNotDetected(() => calls.push("clean"));
			assert.deepEqual(calls, ["clean"], name);
		}
	});

	test("fuckadblock-defuser keeps its stand-ins when the page assigns its own", () => {
		const { self } = run({ [HOST]: [["fuckadblock-defuser", []]] }, HOST, "");
		const stub = self.fuckAdBlock;
		const ctor = self.FuckAdBlock;
		self.fuckAdBlock = { onNotDetected: () => assert.fail("page copy ran") };
		self.FuckAdBlock = function () {};
		assert.equal(self.fuckAdBlock, stub);
		assert.equal(self.FuckAdBlock, ctor);
	});

	test("popads-dummy holds PopAds and popns inert", () => {
		const { self } = run({ [HOST]: [["popads-dummy", []]] }, HOST, "");
		for (const name of ["PopAds", "popns"]) {
			const inert = self[name] as Record<string, unknown>;
			assert.deepEqual(Object.keys(inert), [], name);
			assert.ok(Object.isFrozen(inert), name);
			self[name] = { open: () => {} };
			assert.equal(self[name], inert, name);
		}
	});
});

describe("node text scriptlets", () => {
	const HOST = "www.youtube.com";
	type Mutations = { addedNodes: { nodeName: string; textContent: unknown }[] }[];
	let observers: { cb: (m: Mutations) => void; connected: boolean }[];
	let readyListeners: (() => void)[];

	beforeEach(() => {
		observers = [];
		readyListeners = [];
		Object.assign(globalThis, {
			MutationObserver: class {
				cb: (m: Mutations) => void;
				connected = false;
				constructor(cb: (m: Mutations) => void) {
					this.cb = cb;
					observers.push(this);
				}
				observe() {
					this.connected = true;
				}
				disconnect() {
					this.connected = false;
				}
				takeRecords() {
					return [];
				}
			},
			document: {
				readyState: "loading",
				addEventListener: (_type: string, cb: () => void) => readyListeners.push(cb),
				removeEventListener: () => {}
			}
		});
	});

	afterEach(() => {
		delete (globalThis as Record<string, unknown>).MutationObserver;
		delete (globalThis as Record<string, unknown>).document;
	});

	test("replace-node-text edits the matching script once, then stops", () => {
		run(
			{
				[HOST]: [
					[
						"replace-node-text",
						["script", "/(\\(function serverContract\\(\\))/", "patched();$1", "sedCount", "1", "excludes", "patched", "condition", "/serverContract/"]
					]
				]
			},
			HOST,
			""
		);
		const style = { nodeName: "STYLE", textContent: "(function serverContract(){})" };
		const first = { nodeName: "SCRIPT", textContent: "(function serverContract(){})()" };
		const second = { nodeName: "SCRIPT", textContent: "(function serverContract(){})()" };
		observers[0].cb([{ addedNodes: [style, first, second] }]);
		assert.equal(style.textContent, "(function serverContract(){})");
		assert.equal(first.textContent, "patched();(function serverContract(){})()");
		assert.equal(second.textContent, "(function serverContract(){})()");
		assert.equal(observers[0].connected, false);
	});

	test("replace-node-text writes a script through a Trusted Types policy where the page enforces them", () => {
		const trustedTypes = {
			createPolicy: (_name: string, rules: { createScript: (s: string) => string }) => ({
				createScript: (s: string) => ({ trusted: rules.createScript(s) })
			})
		};
		run({ [HOST]: [["replace-node-text", ["script", "/^go\\(\\)/", "patched();go()"]]] }, HOST, "", [], undefined, { trustedTypes });
		let text = "go()";
		const script = {
			nodeName: "SCRIPT",
			get textContent() {
				return text;
			},
			set textContent(value: unknown) {
				if (typeof value === "string") throw new TypeError("This assignment requires a TrustedScript");
				text = (value as { trusted: string }).trusted;
			}
		};
		observers[0].cb([{ addedNodes: [script] }]);
		assert.equal(text, "patched();go()");
	});

	test("remove-node-text empties matching scripts until the document is interactive", () => {
		run({ [HOST]: [["remove-node-text", ["script", 'window,"fetch"']]] }, HOST, "");
		const grab = { nodeName: "SCRIPT", textContent: 'x(window,"fetch")' };
		const other = { nodeName: "SCRIPT", textContent: "y()" };
		observers[0].cb([{ addedNodes: [grab, other] }]);
		assert.equal(grab.textContent, "");
		assert.equal(other.textContent, "y()");
		assert.equal(observers[0].connected, true);
		(globalThis as unknown as { document: { readyState: string } }).document.readyState = "interactive";
		readyListeners.forEach((cb) => cb());
		assert.equal(observers[0].connected, false);
	});
});

describe("dispatch", () => {
	test("keys hash as Swift's WKEngineFactory.keyHash does", () => {
		assert.deepEqual(["example.com", "www.youtube.com"].map(keyHash), ["Elnf7c/M", "uaB7hAq4"]);
	});

	test("a frame without a host of its own runs its parent's scriptlets", () => {
		const sandbox = run({ "news.example": [["set-constant", ["flag", "true"]]] }, "", "", [], { length: 1, 0: "https://news.example" });
		assert.equal(sandbox.self.flag, true);
	});

	test("hosts sharing an entry each run it, with its args intact", () => {
		const shared = ["set-constant", ["shared", "true"]];
		const table = { "a.example": [shared], "b.example": [shared, ["set-constant", ["quoted", `x,"y'\\`]]] };
		const a = run(table, "www.a.example", "");
		assert.equal(a.self.shared, true);
		assert.equal(a.self.quoted, undefined);
		const b = run(table, "b.example", "");
		assert.equal(b.self.shared, true);
		assert.equal(b.self.quoted, `x,"y'\\`);
	});

	test("a site.* entry matches the site under any public suffix", () => {
		const sandbox = run({ "site.*": [["set-constant", ["flag", "false"]]] }, "www.site.co.uk", "");
		assert.equal(sandbox.self.flag, false);
	});

	test("an exception on the host or a parent drops that scriptlet only, an empty one every scriptlet", () => {
		const table = {
			"site.*": [["set-constant", ["a", "1"]], ["set-constant", ["b", "1"]]],
			"site.com": [["@set-constant", ["a", "1"]]],
			"quiet.site.com": [["@", []]]
		};
		const excepted = run(table, "www.site.com", "");
		assert.equal(excepted.self.a, undefined);
		assert.equal(excepted.self.b, 1);
		assert.equal(run(table, "www.site.org", "").self.a, 1, "the exception is for site.com only");
		assert.equal(run(table, "quiet.site.com", "").self.b, undefined);
	});

	test("a scriptlet listed for both the host and its entity runs once", () => {
		const delays: number[] = [];
		const entry = ["adjust-setTimeout", ["tick", "1000", "0.5"]];
		const sandbox = run({ "site.com": [entry], "site.*": [entry] }, "site.com", "", [], undefined, {
			setTimeout: (_fn: unknown, delay: number) => delays.push(delay)
		});
		(sandbox.self.setTimeout as (fn: () => void, delay: number) => void)(function tick() {}, 1000);
		assert.deepEqual(delays, [500]);
	});
});

// document.cookie as a jar: each write keeps its name=value and records the full cookie string.
type FakeElement = { clicks: number; click(): void; shadowRoot?: FakeDocument };

class FakeDocument {
	jar = new Map<string, string>();
	writes: string[] = [];
	elements = new Map<string, FakeElement>();

	get cookie(): string {
		return [...this.jar].map(([k, v]) => `${k}=${v}`).join("; ");
	}

	set cookie(s: string) {
		this.writes.push(s);
		const pair = s.split(";")[0];
		const at = pair.indexOf("=");
		this.jar.set(pair.slice(0, at), pair.slice(at + 1));
	}

	querySelector(selector: string) {
		return this.elements.get(selector) ?? null;
	}

	add(selector: string) {
		const el: FakeElement = { clicks: 0, click: () => el.clicks++ };
		this.elements.set(selector, el);
		return el;
	}
}

describe("consent scriptlets", () => {
	const HOST = "www.example.fr";
	const g = globalThis as Record<string, unknown>;
	let doc: FakeDocument;
	let storage: Map<string, string>;

	beforeEach(() => {
		doc = new FakeDocument();
		storage = new Map();
		g.document = doc;
		g.localStorage = {
			getItem: (k: string) => storage.get(k) ?? null,
			setItem: (k: string, v: string) => storage.set(k, v),
			removeItem: (k: string) => storage.delete(k)
		};
		mock.timers.enable({ apis: ["setTimeout", "Date"], now: 1_000_000 });
	});

	afterEach(() => {
		mock.timers.reset();
		delete g.document;
		delete g.localStorage;
	});

	test("set-cookie writes a session cookie on path /", () => {
		run({ [HOST]: [["set-cookie", ["cookie_consent", "rejected"]]] }, HOST, "");
		assert.deepEqual(doc.writes, ["cookie_consent=rejected; path=/"]);
	});

	test("trusted-set-cookie expands dates, encodes the value, and sets expiry, domain and Secure", () => {
		run({ [HOST]: [["trusted-set-cookie", ["consent", "t=$now$;all", "1day", "", "domain", ".example.fr"]]] }, HOST, "");
		const expires = new Date(1_000_000 + 86_400_000).toUTCString();
		assert.deepEqual(doc.writes, [
			`consent=t%3D1000000%3Ball; expires=${expires}; path=/; domain=.example.fr; Secure`
		]);
	});

	test("a reload option reloads once the cookie changed, and not when it already holds the value", () => {
		const table = { [HOST]: [["trusted-set-cookie", ["consent", "1", "", "", "reload", "1"]]] };
		const first = run(table, HOST, "");
		assert.equal(first.location.reloads, 1);
		const second = run(table, HOST, "");
		assert.equal(second.location.reloads, 0);
		assert.equal(doc.writes.length, 1);
	});

	test("local storage items are set, expanded, and removed", () => {
		storage.set("old", "x");
		run(
			{
				[HOST]: [
					["set-local-storage-item", ["prefs", "emptyObj"]],
					["trusted-set-local-storage-item", ["seen", "$now$"]],
					["set-local-storage-item", ["old", "$remove$"]]
				]
			},
			HOST,
			""
		);
		assert.deepEqual([...storage], [["prefs", "{}"], ["seen", "1000000"]]);
	});

	test("trusted-click-element clicks a single selector after its delay, once it appears", () => {
		run({ [HOST]: [["trusted-click-element", ["button.reject", "", "1000"]]] }, HOST, "");
		mock.timers.tick(500);
		const button = doc.add("button.reject");
		mock.timers.tick(400);
		assert.equal(button.clicks, 0);
		mock.timers.tick(200);
		assert.equal(button.clicks, 1);
		mock.timers.tick(20_000);
		assert.equal(button.clicks, 1);
	});

	test("trusted-click-element clicks a sequence in order, a delay apart, through open shadow roots", () => {
		const host = doc.add("#cmp");
		host.shadowRoot = new FakeDocument();
		const settings = doc.add("button.settings");
		const deny = host.shadowRoot.add("button.deny");
		run({ [HOST]: [["trusted-click-element", ["button.settings, #cmp >>> button.deny", "", "500"]]] }, HOST, "");
		assert.equal(settings.clicks, 1);
		assert.equal(deny.clicks, 0);
		mock.timers.tick(500);
		assert.equal(deny.clicks, 1);
	});

	test("trusted-click-element gives up after 10 s, and skips rules with an extra condition", () => {
		run(
			{
				[HOST]: [
					["trusted-click-element", ["button.late"]],
					["trusted-click-element", ["button.cond", "cookie:consent"]]
				]
			},
			HOST,
			""
		);
		const cond = doc.add("button.cond");
		mock.timers.tick(10_100);
		const late = doc.add("button.late");
		mock.timers.tick(1_000);
		assert.equal(late.clicks, 0);
		assert.equal(cond.clicks, 0);
	});
});

describe("anti-detection scriptlets", () => {
	test("bab-defuser skips BlockAdBlock's eval and its bait timer, nothing else", () => {
		const evaluated: string[] = [];
		const timers: unknown[] = [];
		const body = { style: { removed: "", removeProperty(p: string) { this.removed = p; } } };
		const notice = { removed: false, remove() { this.removed = true; } };
		const doc = { readyState: "complete", body, getElementById: (id: string) => (id === "babasbmsgx" ? notice : null) };
		(globalThis as Record<string, unknown>).document = doc;
		try {
			const { self } = run({ "example.com": [["bab-defuser", []]] }, "example.com", "", [], undefined, {
				eval: (code: string) => evaluated.push(code),
				setTimeout: (cb: unknown) => timers.push(cb)
			});
			const loader = `var x='${"a".repeat(600)}';localStorage.getItem('babn');`;
			(self.eval as (c: string) => void)(loader);
			(self.eval as (c: string) => void)("1 + 1");
			(self.setTimeout as (c: unknown) => void)("check(document.querySelector('.bab_elementid.'))");
			(self.setTimeout as (c: unknown) => void)("tick()");
			assert.deepEqual(evaluated, ["1 + 1"]);
			assert.deepEqual(timers, ["tick()"]);
			assert.equal(body.style.removed, "visibility");
			assert.equal(notice.removed, true);
		} finally {
			delete (globalThis as Record<string, unknown>).document;
		}
	});

	test("nowebrtc replaces peer connections with ones that never negotiate", async () => {
		class NativePeerConnection {}
		const { self } = run({ "example.com": [["nowebrtc", []]] }, "example.com", "", [], undefined, {
			RTCPeerConnection: NativePeerConnection
		});
		const Ctor = self.RTCPeerConnection as new () => Record<string, (...a: unknown[]) => unknown> & EventTarget;
		assert.notEqual(Ctor, NativePeerConnection);
		const pc = new Ctor();
		assert.ok(pc instanceof Ctor);
		assert.ok(pc instanceof EventTarget);
		await assert.rejects(pc.createOffer() as Promise<unknown>, { name: "NotAllowedError" });
		assert.equal(pc.connectionState, "closed");
		assert.deepEqual(pc.getSenders(), []);
		const channel = pc.createDataChannel("x") as unknown as { readyState: string; send: () => void };
		assert.equal(channel.readyState, "closed");
		channel.send();
		assert.equal(Object.keys(NativePeerConnection.prototype).length, 0, "the native class is not patched");
	});
});

describe("element scriptlets", () => {
	class FakeRect {
		x: number;
		y: number;
		width: number;
		height: number;
		constructor(x: number, y: number, width: number, height: number) {
			this.x = x;
			this.y = y;
			this.width = width;
			this.height = height;
		}
	}
	// An element matching a selector list of `.class` names.
	class FakeElement {
		classes: string[];
		localName: string;
		parentElement: FakeElement | null;
		attrs: Record<string, string>;
		constructor(classes: string[], localName = "div", parentElement: FakeElement | null = null, attrs: Record<string, string> = {}) {
			this.classes = classes;
			this.localName = localName;
			this.parentElement = parentElement;
			this.attrs = attrs;
		}
		matches(selector: string): boolean {
			return selector.split(",").some((s) => this.classes.includes(s.trim().slice(1)));
		}
		hasAttribute(name: string): boolean {
			return name in this.attrs;
		}
		click(): string {
			return "clicked";
		}
		getBoundingClientRect(): FakeRect {
			return new FakeRect(1, 2, 30, 40);
		}
	}

	test("trusted-override-element-method stops the method on matching elements only", () => {
		const { self } = run(
			{ "example.com": [["trusted-override-element-method", ["Element.prototype.click", ".popunder"]]] },
			"example.com",
			"",
			[],
			undefined,
			{ Element: FakeElement }
		);
		const Element = self.Element as typeof FakeElement;
		assert.equal(new Element(["popunder"]).click(), undefined);
		assert.equal(new Element(["link"]).click(), "clicked");
	});

	test("trusted-override-element-method throws when told to", () => {
		const { self } = run(
			{ "example.com": [["trusted-override-element-method", ["Element.prototype.click", ".popunder", "throw"]]] },
			"example.com",
			"",
			[],
			undefined,
			{ Element: FakeElement }
		);
		const Element = self.Element as typeof FakeElement;
		assert.throws(() => new Element(["popunder"]).click(), ReferenceError);
	});

	test("spoof-css reports the spoofed values of matching elements, dashed or camel-cased", () => {
		const style = {
			display: "none",
			visibility: "hidden",
			getPropertyValue(name: string) {
				return name === "display" ? this.display : this.visibility;
			}
		};
		const { self } = run(
			{ "example.com": [["spoof-css", [".ad, .slot", "display", "block", "_rectw", "300", "_debug", "1"]]] },
			"example.com",
			"",
			[],
			undefined,
			{ Element: FakeElement, DOMRect: FakeRect, getComputedStyle: () => style }
		);
		const Element = self.Element as typeof FakeElement;
		const getComputedStyle = self.getComputedStyle as (el: unknown) => typeof style;
		const ad = new Element(["slot"]);
		assert.equal(getComputedStyle(ad).display, "block");
		assert.equal(getComputedStyle(ad).getPropertyValue("display"), "block");
		assert.equal(getComputedStyle(ad).visibility, "hidden");
		assert.equal(getComputedStyle(ad).getPropertyValue("visibility"), "hidden");
		assert.equal(getComputedStyle(new Element(["other"])).display, "none");
		const rect = ad.getBoundingClientRect();
		assert.deepEqual([rect.x, rect.y, rect.width, rect.height], [1, 2, 300, 40]);
		assert.equal(new Element(["other"]).getBoundingClientRect().width, 30);
	});

	test("disable-newtab-links cancels a click inside a link with a target", () => {
		const listeners: ((e: unknown) => void)[] = [];
		(globalThis as Record<string, unknown>).document = { addEventListener: (_t: string, cb: (e: unknown) => void) => listeners.push(cb) };
		try {
			run({ "example.com": [["disable-newtab-links", []]] }, "example.com", "");
			const click = (target: FakeElement) => {
				const event = {
					target,
					cancelled: false,
					preventDefault() {
						this.cancelled = true;
					},
					stopPropagation() {}
				};
				for (const cb of listeners) cb(event);
				return event.cancelled;
			};
			const blank = new FakeElement([], "a", null, { target: "_blank" });
			assert.equal(click(new FakeElement([], "span", blank)), true);
			assert.equal(click(new FakeElement([], "a", null, { href: "/next" })), false);
		} finally {
			delete (globalThis as Record<string, unknown>).document;
		}
	});
});
