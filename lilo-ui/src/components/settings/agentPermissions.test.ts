import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { normalizeSite } from "./agentPermissions";

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
