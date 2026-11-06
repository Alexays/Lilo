import assert from "node:assert/strict";
import test from "node:test";

import { arrangeRows, keepSameGroups, nextStackHosts, stackEntries, stackName, strippedTitle, type ArrangeEntry } from "./tabSectionModel";

const web = (id: string, host: string): ArrangeEntry => ({ id, type: "web", host });
const term = (id: string): ArrangeEntry => ({ id, type: "terminal", host: null });
const agent = (id: string): ArrangeEntry => ({ id, type: "agent", host: null });

test("a site stacks at three tabs and holds until one is left", () => {
	const two = [web("a", "x.example"), web("b", "x.example")];
	assert.deepEqual([...nextStackHosts(two, new Set(), new Set())], []);
	const three = [...two, web("c", "x.example")];
	const stacked = nextStackHosts(three, new Set(), new Set());
	assert.deepEqual([...stacked], ["x.example"]);
	assert.deepEqual([...nextStackHosts(two, stacked, new Set())], ["x.example"]);
	assert.deepEqual([...nextStackHosts(two.slice(1), stacked, new Set())], []);
});

test("a site the user excluded never stacks", () => {
	const three = [web("a", "x.example"), web("b", "x.example"), web("c", "x.example")];
	assert.deepEqual([...nextStackHosts(three, new Set(), new Set(["x.example"]))], []);
});

test("a stack gathers its members at its first member's place", () => {
	const rows = arrangeRows(
		[web("a", "x.example"), web("b", "y.example"), web("c", "x.example"), web("d", "y.example"), web("e", "x.example")],
		new Set(["x.example"]),
		false,
	);
	assert.deepEqual(rows.map((row) => row.id), ["a", "c", "e", "b", "d"]);
	assert.deepEqual(rows.map((row) => row.stack), ["x.example", "x.example", "x.example", null, null]);
});

test("grouped rows put agents then terminals in trays above the web, each in list order", () => {
	const rows = arrangeRows([web("w1", "x.example"), term("t1"), agent("a1"), web("w2", "y.example"), term("t2")], new Set(), true);
	assert.deepEqual(rows.map((row) => row.id), ["a1", "t1", "t2", "w1", "w2"]);
	assert.deepEqual(rows.map((row) => row.tray), ["agent", "terminal", "terminal", null, null]);
});

test("one kind of tab alone gets no tray", () => {
	const rows = arrangeRows([term("t1"), term("t2")], new Set(), true);
	assert.deepEqual(rows.map((row) => row.tray), [null, null]);
});

test("the stack name is the part titles share, else the host", () => {
	const titles = ["Commits · acme/app", "acme/app: The core of Acme", "Release 0.81.0 · acme/app"];
	assert.equal(stackName(titles, "code.example.com"), "acme/app");
	assert.equal(stackName(["Inbox", "Sent"], "mail.example.com"), "mail.example.com");
	assert.equal(strippedTitle("Commits · acme/app", "acme/app"), "Commits");
	assert.equal(strippedTitle("acme/app: The core of Acme", "acme/app"), "The core of Acme");
	assert.equal(strippedTitle("acme/app", "acme/app"), "acme/app");
});

test("a stack its hosts still name but down to one tab is a plain row", () => {
	const rows = arrangeRows([web("a", "x.example"), web("b", "y.example")], new Set(["x.example"]), false);
	assert.deepEqual(rows.map((row) => row.stack), [null, null]);
});

test("a stack of the very same tabs keeps its entry, one whose titles held keeps its name", () => {
	const one = { id: "a", title: "Commits · acme/app" };
	const two = { id: "b", title: "Issues · acme/app" };
	const first = stackEntries(new Map([["code.example.com", [one, two]]]), new Map());
	assert.deepEqual(first.get("code.example.com"), { name: "acme/app", tabs: [one, two] });

	const same = stackEntries(new Map([["code.example.com", [one, two]]]), first);
	assert.equal(same.get("code.example.com"), first.get("code.example.com"));

	const loading = { ...two, progress: 0.5 };
	const patched = stackEntries(new Map([["code.example.com", [one, loading]]]), same);
	assert.notEqual(patched.get("code.example.com"), same.get("code.example.com"));
	assert.deepEqual(patched.get("code.example.com"), { name: "acme/app", tabs: [one, loading] });

	const renamed = stackEntries(new Map([["code.example.com", [{ ...one, title: "Commits" }, { ...two, title: "Issues" }]]]), patched);
	assert.equal(renamed.get("code.example.com")?.name, "code.example.com");
});

test("a tray of the very same tabs keeps its array", () => {
	const one = { id: "a" };
	const two = { id: "b" };
	const last = new Map([["agent", [one]], ["terminal", [two]]]);
	const next = keepSameGroups(new Map([["agent", [one]], ["terminal", [{ ...two }]]]), last);
	assert.equal(next.get("agent"), last.get("agent"));
	assert.notEqual(next.get("terminal"), last.get("terminal"));
	assert.notEqual(keepSameGroups(new Map([["agent", [one, two]]]), last).get("agent"), last.get("agent"));
});
