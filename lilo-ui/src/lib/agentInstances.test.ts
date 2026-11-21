import assert from "node:assert/strict";
import test from "node:test";

import { disabledAgentIds, newCommandId, parseAgentInstances, writeAgentInstances } from "./agentInstances";

test("parses the instances list and drops malformed entries", () => {
  const instances = parseAgentInstances(
    JSON.stringify([
      { id: "codex-acp", source: "registry", registryId: "codex-acp", enabled: true },
      { id: "command-1", source: "command", name: "Mine", executable: "/usr/local/bin/mine", enabled: false },
      { id: "", source: "registry" },
      { id: "no-source" },
      { source: "command" },
      "not an object",
      { id: "odd-enabled", source: "registry", enabled: "yes" },
    ]),
  );
  assert.deepEqual(
    instances.map((instance) => instance.id),
    ["codex-acp", "command-1"],
  );
});

test("an absent enabled flag means enabled", () => {
  const [instance] = parseAgentInstances(JSON.stringify([{ id: "a", source: "registry" }]));
  assert.equal(instance.enabled, true);
});

test("empty and invalid input parses to no instances", () => {
  assert.deepEqual(parseAgentInstances(""), []);
  assert.deepEqual(parseAgentInstances("not json"), []);
  assert.deepEqual(parseAgentInstances("{}"), []);
});

test("round-trips the list without empty fields", () => {
  const instances = [
    { id: "gemini", source: "registry" as const, registryId: "gemini", name: "Gemini", enabled: false },
    { id: "command-2", source: "command" as const, name: "Mine", executable: "/opt/mine", arguments: "--profile\nacp", environment: "TOKEN=1", enabled: true },
  ];
  const parsed = parseAgentInstances(writeAgentInstances(instances));
  assert.deepEqual(parsed, instances);
  const stored = JSON.parse(writeAgentInstances([{ id: "a", source: "registry", enabled: true }]));
  assert.deepEqual(stored, [{ id: "a", source: "registry", enabled: true }]);
});

test("disabled ids use the registry id for registry entries, the id for commands", () => {
  const ids = disabledAgentIds([
    { id: "entry", source: "registry", registryId: "codex-acp", enabled: false },
    { id: "command-9", source: "command", enabled: false },
    { id: "other", source: "registry", registryId: "gemini", enabled: true },
  ]);
  assert.deepEqual([...ids].sort(), ["codex-acp", "command-9"]);
});

test("new command ids are unique and namespaced", () => {
  const first = newCommandId();
  const second = newCommandId();
  assert.match(first, /^command-/);
  assert.notEqual(first, second);
});
