import assert from "node:assert/strict";
import test from "node:test";

import { arrangeRows, nextStackHosts, stackName, strippedTitle, windowRows, type ArrangeEntry } from "./tabSectionModel";

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

test("rows out of the window fold into spacers that keep the list's height", () => {
	const ids = Array.from({ length: 10 }, (_, index) => `r${index}`);
	// 32px rows, 34px apart: r3 to r5 cross [120, 200].
	const rows = windowRows(ids, 0, 120, 200, () => 32, (id) => id === "r9");
	assert.deepEqual(
		rows.map((row) => (row.kind === "spacer" ? row.height : `${row.item}@${row.top}`)),
		[3 * 32 + 2 * 2, "r3@102", "r4@136", "r5@170", 3 * 32 + 2 * 2, "r9@306"],
	);
	assert.deepEqual(rows.flatMap((row) => (row.kind === "spacer" ? [row.key] : [])), ["spacer-0", "spacer-1"]);
});

test("rows laid out from a folder's offset window against the same range", () => {
	const rows = windowRows(["a", "b"], 1000, 0, 500, () => 32, () => false);
	assert.deepEqual(rows, [{ kind: "spacer", key: "spacer-0", height: 66 }]);
});

test("a stack its hosts still name but down to one tab is a plain row", () => {
	const rows = arrangeRows([web("a", "x.example"), web("b", "y.example")], new Set(["x.example"]), false);
	assert.deepEqual(rows.map((row) => row.stack), [null, null]);
});
