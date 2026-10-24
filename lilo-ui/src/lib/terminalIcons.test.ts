import test from "node:test";
import assert from "node:assert/strict";
import { terminalProgramIcon } from "./terminalIcons";

test("terminalProgramIcon reads the program from the first word", () => {
  assert.ok(terminalProgramIcon("npm run dev"));
  assert.equal(terminalProgramIcon("npm run dev"), terminalProgramIcon("npx vite"));
  assert.ok(terminalProgramIcon("claude"));
});

test("terminalProgramIcon skips wrappers, assignments and the path", () => {
  assert.equal(terminalProgramIcon("sudo FOO=1 /usr/local/bin/python3.12 x.py"), terminalProgramIcon("python"));
  assert.equal(terminalProgramIcon("env -i nvim"), terminalProgramIcon("nvim"));
});

test("terminalProgramIcon has no logo for an unknown program or an empty line", () => {
  assert.equal(terminalProgramIcon("ls -la"), undefined);
  assert.equal(terminalProgramIcon(""), undefined);
  assert.equal(terminalProgramIcon("   "), undefined);
});

test("terminalProgramIcon has no logo for a program named after an Object member", () => {
  assert.equal(terminalProgramIcon("constructor"), undefined);
  assert.equal(terminalProgramIcon("toString --help"), undefined);
});
