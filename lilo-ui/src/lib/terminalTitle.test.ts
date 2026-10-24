import assert from "node:assert/strict";
import test from "node:test";

import { terminalFolder, terminalTitle } from "./terminalTitle";

test("terminal folder is the last path component, ~ for home", () => {
  assert.equal(terminalFolder("/Users/me/Projects/acme/app"), "app");
  assert.equal(terminalFolder("/Users/me"), "~");
  assert.equal(terminalFolder("/Users/me/"), "~");
  assert.equal(terminalFolder("/tmp/build/"), "build");
  assert.equal(terminalFolder("/"), "/");
  assert.equal(terminalFolder(""), "");
});

test("a running command titles the row with its own title, then its command line", () => {
  const cwd = "/Users/me/Projects/Lilo";
  assert.equal(terminalTitle({ terminalState: "waiting", title: "Fix the energy use", terminalCommand: "claude", cwd }), "Fix the energy use");
  assert.equal(terminalTitle({ terminalState: "busy", title: "", terminalCommand: "npm run dev", cwd }), "npm run dev");
  assert.equal(terminalTitle({ terminalState: "busy", terminalCommand: "  ", cwd }), "Lilo");
});

test("a terminal at its prompt shows its folder, whatever title is left", () => {
  const cwd = "/Users/me/Projects/Lilo";
  assert.equal(terminalTitle({ terminalState: "failed", title: "Claude Code", terminalCommand: "cargo test", cwd }), "Lilo");
  assert.equal(terminalTitle({ terminalState: "idle", title: "Lilo", cwd }), "Lilo");
  assert.equal(terminalTitle({}), "");
});
