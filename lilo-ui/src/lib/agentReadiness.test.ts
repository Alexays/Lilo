import assert from "node:assert/strict";
import { test } from "node:test";
import type { BridgeAgentInfo } from "./bridge/protocol";
import { agentNote, agentStatus, isPickable, modelControl, parseModelId, signInMethods } from "./agentReadiness";

const labels = { needsSignIn: "Needs sign-in", unavailable: "Unavailable", unverified: "Couldn't check" };
const agent = (readiness?: BridgeAgentInfo["readiness"]): BridgeAgentInfo => ({ id: "a", name: "A", description: "", readiness });
const record = (state: NonNullable<BridgeAgentInfo["readiness"]>["state"], more: object = {}) => ({ state, probedAt: 1, ...more });

test("an agent nobody probed is unknown and still pickable", () => {
	assert.equal(agentStatus(agent()), "unknown");
	assert.equal(isPickable(agent()), true);
	assert.equal(agentNote(agent(), labels), undefined);
});

test("only an agent that cannot start is out of the picker's reach", () => {
	assert.equal(isPickable(agent(record("ready"))), true);
	assert.equal(isPickable(agent(record("needsSignIn"))), true);
	assert.equal(isPickable(agent(record("unverified"))), true);
	assert.equal(isPickable(agent(record("unavailable"))), false);
});

test("the note is the agent's own reason, else the status's name", () => {
	assert.equal(agentNote(agent(record("ready")), labels), undefined);
	assert.equal(agentNote(agent(record("unavailable", { reason: "Example needs Node.js." })), labels), "Example needs Node.js.");
	assert.equal(agentNote(agent(record("unavailable", { reason: "  " })), labels), "Unavailable");
	assert.equal(agentNote(agent(record("needsSignIn", { reason: "auth_required" })), labels), "Needs sign-in");
	assert.equal(agentNote(agent(record("unverified")), labels), "Couldn't check");
});

test("only the sign-in methods Lilo can run are offered", () => {
	const methods = [
		{ id: "browser", name: "Browser", type: "agent" },
		{ id: "cli", name: "Terminal", type: "terminal" },
		{ id: "key", name: "Key", type: "env_var" },
	];
	assert.deepEqual(signInMethods(agent(record("needsSignIn", { authMethods: methods }))).map((method) => method.id), ["browser", "cli"]);
	assert.deepEqual(signInMethods(agent()), []);
});

test("the models of a record show before the session has any", () => {
	const models = [{ id: "m1", name: "One" }, { id: "m2", name: "Two" }];
	const ready = agent(record("ready", { models, modelConfigId: "model", currentModel: "m1" }));
	assert.deepEqual(modelControl(ready, { hasModels: false, opened: false }), { kind: "list", configId: "model", current: "m1", options: models });
	assert.equal(modelControl(ready, { hasModels: true, opened: true }), null);
});

test("an agent with no models offers a field to type one, never an empty picker", () => {
	assert.deepEqual(modelControl(agent(record("ready")), { hasModels: false, opened: false }), { kind: "custom" });
	assert.deepEqual(modelControl(agent(), { hasModels: false, opened: true }), { kind: "custom" });
	// Nothing is known yet: no control rather than a guess.
	assert.equal(modelControl(agent(), { hasModels: false, opened: false }), null);
	assert.equal(modelControl(undefined, { hasModels: false, opened: true }), null);
	assert.equal(modelControl(agent(record("unavailable")), { hasModels: false, opened: true }), null);
});

test("models Lilo cannot set leave neither a list nor a field", () => {
	const legacy = agent(record("ready", { models: [{ id: "m1", name: "One" }] }));
	assert.equal(modelControl(legacy, { hasModels: false, opened: true }), null);
});

test("a model id is one word", () => {
	assert.equal(parseModelId("  gpt-5.5 "), "gpt-5.5");
	assert.equal(parseModelId("two words"), null);
	assert.equal(parseModelId("   "), null);
});
