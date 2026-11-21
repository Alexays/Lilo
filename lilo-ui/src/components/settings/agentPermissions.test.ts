import assert from "node:assert/strict";
import { describe, it } from "node:test";


import { normalizeSite, parseAgentPermissions, setAgentPermission } from "./agentPermissions";

describe("parseAgentPermissions", () => {
  it("treats nothing stored, garbage and a non-object as no client set", () => {
    assert.deepEqual(parseAgentPermissions(""), {});
    assert.deepEqual(parseAgentPermissions("not json"), {});
    assert.deepEqual(parseAgentPermissions("[1]"), {});
    assert.deepEqual(parseAgentPermissions("null"), {});
  });

  it("reads what Swift writes and falls back to the safe default for anything else", () => {
    const stored = JSON.stringify({ Codex: { act: "always", sites: ["example.com"] }, Zed: { act: "root" }, Odd: { sites: [1, "a.test"] } });
    assert.deepEqual(parseAgentPermissions(stored), {
      Codex: { act: "always", sites: ["example.com"] },
      Zed: { act: "ask", sites: [] },
      Odd: { act: "ask", sites: ["a.test"] },
    });
  });
});

describe("setAgentPermission", () => {
  it("keeps the other clients and drops one back at the default", () => {
    const stored = setAgentPermission("", "Codex", { act: "always", sites: [] });
    const both = setAgentPermission(stored, "Zed", { act: "ask", sites: ["example.com"] });
    assert.deepEqual(parseAgentPermissions(both), { Codex: { act: "always", sites: [] }, Zed: { act: "ask", sites: ["example.com"] } });
    assert.deepEqual(parseAgentPermissions(setAgentPermission(both, "Codex", { act: "ask", sites: [] })), {
      Zed: { act: "ask", sites: ["example.com"] },
    });
  });
});

describe("normalizeSite", () => {
  it("reduces a typed or pasted address to its host", () => {
    assert.equal(normalizeSite(" Shop.Example.com "), "shop.example.com");
    assert.equal(normalizeSite("https://Shop.Example.com/cart?a=1"), "shop.example.com");
    assert.equal(normalizeSite("localhost"), "localhost");
  });

  it("refuses what is no host", () => {
    for (const input of ["", "   ", "not a host", "example", "http://", "a b.com"]) assert.equal(normalizeSite(input), "", input);
  });
});
