import assert from "node:assert/strict";
import test from "node:test";

import { parseAgentCommands, parseHiddenAgents } from "./agentCommands";

test("parses the commands, drops entries without an id and fills missing fields", () => {
  const commands = parseAgentCommands(
    JSON.stringify([
      { id: "command-1", name: "Mine", executable: "/usr/local/bin/mine", arguments: "--acp" },
      { id: "", executable: "/bin/a" },
      { executable: "/bin/b" },
      "not an object",
      null,
    ]),
  );
  assert.deepEqual(commands, [{ id: "command-1", name: "Mine", executable: "/usr/local/bin/mine", arguments: "--acp", environment: "" }]);
});

test("empty and invalid input parses to nothing", () => {
  for (const stored of ["", "not json", "{}"]) {
    assert.deepEqual(parseAgentCommands(stored), []);
    assert.deepEqual([...parseHiddenAgents(stored)], []);
  }
});

test("hidden agents keep only string ids", () => {
  assert.deepEqual([...parseHiddenAgents(JSON.stringify(["gemini", 3, "command-1"]))], ["gemini", "command-1"]);
});
