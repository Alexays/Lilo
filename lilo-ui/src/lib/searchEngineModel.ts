// Pure, i18n-free model for the engine list persisted as JSON in the `searchEngines` setting.

export interface SearchEngine {
  id: string;
  name: string;
  /** URL template containing `%s`, replaced by the URL-encoded query. */
  urlTemplate: string;
  /** Optional omnibox keyword ("yt foo" searches this engine); "" = none. */
  keyword: string;
}

export const BUILTIN_SEARCH_ENGINES: readonly SearchEngine[] = [
  { id: "google", name: "Google", urlTemplate: "https://www.google.com/search?q=%s", keyword: "" },
  { id: "duckduckgo", name: "DuckDuckGo", urlTemplate: "https://duckduckgo.com/?q=%s", keyword: "" },
  { id: "bing", name: "Bing", urlTemplate: "https://www.bing.com/search?q=%s", keyword: "" },
  { id: "brave", name: "Brave Search", urlTemplate: "https://search.brave.com/search?q=%s", keyword: "" },
];

function builtinsCopy(): SearchEngine[] {
  return BUILTIN_SEARCH_ENGINES.map((engine) => ({ ...engine }));
}

function normalizeEngine(raw: unknown): SearchEngine | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const id = typeof o.id === "string" ? o.id.trim() : "";
  const name = typeof o.name === "string" ? o.name.trim() : "";
  const urlTemplate = typeof o.urlTemplate === "string" ? o.urlTemplate.trim() : "";
  const keyword = typeof o.keyword === "string" ? o.keyword.trim() : "";
  if (!id || !name || !urlTemplate) return null;
  return { id, name, urlTemplate, keyword };
}

/** Falls back to the built-ins for missing/invalid/empty input. */
export function parseSearchEngines(json: string | undefined | null): SearchEngine[] {
  if (!json) return builtinsCopy();
  try {
    const parsed = JSON.parse(json);
    if (!Array.isArray(parsed)) return builtinsCopy();
    const engines = parsed
      .map(normalizeEngine)
      .filter((engine): engine is SearchEngine => engine !== null);
    return engines.length > 0 ? engines : builtinsCopy();
  } catch {
    return builtinsCopy();
  }
}

/** Appends the encoded query when the template has no `%s` placeholder. */
export function buildSearchURLFromTemplate(template: string, query: string): string {
  const encoded = encodeURIComponent(query);
  return template.includes("%s") ? template.replaceAll("%s", encoded) : template + encoded;
}

export function findEngineById(engines: SearchEngine[], id: string | undefined): SearchEngine | undefined {
  return id ? engines.find((engine) => engine.id === id) : undefined;
}

export function findEngineByKeyword(engines: SearchEngine[], word: string): SearchEngine | undefined {
  const needle = word.trim().toLowerCase();
  if (!needle) return undefined;
  return engines.find((engine) => engine.keyword && engine.keyword.toLowerCase() === needle);
}

// ---- Editor mutations (pure) ----

export function moveSearchEngine(engines: SearchEngine[], index: number, direction: -1 | 1): SearchEngine[] {
  const target = index + direction;
  if (index < 0 || index >= engines.length || target < 0 || target >= engines.length) return engines;
  const next = [...engines];
  [next[index], next[target]] = [next[target], next[index]];
  return next;
}
