import assert from "node:assert/strict";
import { test } from "node:test";
import {
  BUILTIN_SEARCH_ENGINES,
  buildSearchURLFromTemplate,
  findEngineByKeyword,
  moveSearchEngine,
  parseSearchEngines,
  type SearchEngine,
} from "./searchEngineModel";

test("parseSearchEngines falls back to built-ins for empty/invalid input", () => {
  assert.equal(parseSearchEngines(undefined).length, BUILTIN_SEARCH_ENGINES.length);
  assert.equal(parseSearchEngines("").length, BUILTIN_SEARCH_ENGINES.length);
  assert.equal(parseSearchEngines("not json").length, BUILTIN_SEARCH_ENGINES.length);
  assert.equal(parseSearchEngines("{}").length, BUILTIN_SEARCH_ENGINES.length);
  assert.equal(parseSearchEngines("[]").length, BUILTIN_SEARCH_ENGINES.length);
});

test("parseSearchEngines keeps valid entries and drops malformed ones", () => {
  const json = JSON.stringify([
    { id: "k", name: "Example", urlTemplate: "https://search.example.com/?q=%s", keyword: "k" },
    { id: "", name: "bad", urlTemplate: "x" }, // missing id
    { name: "no-id-no-template" }, // invalid
  ]);
  const engines = parseSearchEngines(json);
  assert.equal(engines.length, 1);
  assert.equal(engines[0]!.id, "k");
  assert.equal(engines[0]!.keyword, "k");
});

test("serialize then parse round-trips", () => {
  const engines: SearchEngine[] = [
    { id: "a", name: "A", urlTemplate: "https://a/?q=%s", keyword: "a" },
  ];
  assert.deepEqual(parseSearchEngines(JSON.stringify(engines)), engines);
});

test("buildSearchURLFromTemplate substitutes %s and encodes the query", () => {
  assert.equal(
    buildSearchURLFromTemplate("https://www.google.com/search?q=%s", "a b&c"),
    "https://www.google.com/search?q=a%20b%26c",
  );
});

test("buildSearchURLFromTemplate appends when the template has no %s", () => {
  assert.equal(buildSearchURLFromTemplate("https://x/?q=", "cats"), "https://x/?q=cats");
});

test("findEngineByKeyword matches case-insensitively and ignores empty keywords", () => {
  const engines: SearchEngine[] = [
    { id: "g", name: "Google", urlTemplate: "g/%s", keyword: "" },
    { id: "y", name: "YouTube", urlTemplate: "y/%s", keyword: "yt" },
  ];
  assert.equal(findEngineByKeyword(engines, "YT")!.id, "y");
  assert.equal(findEngineByKeyword(engines, "nope"), undefined);
  assert.equal(findEngineByKeyword(engines, ""), undefined);
});

test("moveSearchEngine swaps within bounds and is a no-op at edges", () => {
  const engines: SearchEngine[] = [
    { id: "a", name: "A", urlTemplate: "a", keyword: "" },
    { id: "b", name: "B", urlTemplate: "b", keyword: "" },
  ];
  assert.deepEqual(moveSearchEngine(engines, 0, 1).map((e) => e.id), ["b", "a"]);
  assert.deepEqual(moveSearchEngine(engines, 0, -1).map((e) => e.id), ["a", "b"]);
});
