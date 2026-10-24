import assert from "node:assert/strict";
import test, { mock } from "node:test";

type Receiver = {
	receive(msg: Record<string, unknown>): void;
	receiveBatch(msgs: Record<string, unknown>[]): void;
};

(globalThis as { window?: unknown }).window = { __liloBootstrapEvents: [] };
const { on } = await import("./index");
const receiver = (globalThis as unknown as { window: { __lilo: Receiver } }).window.__lilo;

test("a throwing handler leaves the others and the rest of the batch delivered, then reaches native", () => {
	const error = mock.method(console, "error", () => {});
	const seen: string[] = [];
	const disposers = [
		on("urlCopied", () => {
			throw new Error("boom");
		}),
		on("urlCopied", () => seen.push("second handler")),
		on("urlCopyFailed", () => seen.push("next message")),
	];
	try {
		assert.throws(
			() => receiver.receiveBatch([{ event: "urlCopied" }, { event: "urlCopyFailed" }]),
			/boom/,
			"the call still fails for native to log",
		);
		assert.deepEqual(seen, ["second handler", "next message"]);
		assert.equal(error.mock.callCount(), 1);
	} finally {
		for (const dispose of disposers) dispose();
		error.mock.restore();
	}
});
