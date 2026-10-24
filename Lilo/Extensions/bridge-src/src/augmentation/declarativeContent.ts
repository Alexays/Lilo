// Lilo shows every extension's action on every page, so onPageChanged rules are kept as Chrome keeps them but never
// act. SW-safe: no window/document/webkit.
import { callbackify } from '../shared/callbackify.ts';

interface Rule {
  id?: string;
  priority?: number;
  tags?: string[];
  conditions: unknown[];
  actions: unknown[];
}

/** A constructor whose instances carry their options and Chrome's instanceType. */
const declarative = (type: string) => function (this: Record<string, unknown>, options?: Record<string, unknown>) {
  Object.assign(this, options, { instanceType: `declarativeContent.${type}` });
} as unknown as new (options?: Record<string, unknown>) => Record<string, unknown>;

const rules = new Map<string, Rule>();
let nextId = 0;

const selected = (ids?: unknown) => (Array.isArray(ids) ? ids.filter((id) => rules.has(id)) : [...rules.keys()]);

export const declarativeContentAugmentation = {
  PageStateMatcher: declarative('PageStateMatcher'),
  ShowAction: declarative('ShowAction'),
  ShowPageAction: declarative('ShowPageAction'),
  SetIcon: declarative('SetIcon'),
  RequestContentScript: declarative('RequestContentScript'),
  onPageChanged: {
    // A declarative event takes rules only.
    addListener() { throw new Error('This event does not support listeners.'); },
    removeListener() { throw new Error('This event does not support listeners.'); },
    hasListener: () => false,
    hasListeners: () => false,
    addRules(added: Rule[], callback?: (rules: Rule[]) => void) {
      return callbackify(async () => added.map((rule) => {
        const kept = { ...rule, id: rule.id ?? `_${++nextId}_`, priority: rule.priority ?? 100, tags: rule.tags ?? [] };
        rules.set(kept.id, kept);
        return kept;
      }), callback);
    },
    removeRules(ids?: string[] | (() => void), callback?: () => void) {
      if (typeof ids === 'function') [ids, callback] = [undefined, ids];
      const removed = selected(ids);
      return callbackify(async () => { for (const id of removed) rules.delete(id); }, callback);
    },
    getRules(ids?: string[] | ((rules: Rule[]) => void), callback?: (rules: Rule[]) => void) {
      if (typeof ids === 'function') [ids, callback] = [undefined, ids];
      const found = selected(ids).map((id) => rules.get(id)!);
      return callbackify(async () => found, callback);
    },
  },
};
