// The app follows NSAppearance through matchMedia. The demo supplies the same signal locally.
export const installDemoAppearance = () => {
  const nativeMatchMedia = window.matchMedia.bind(window);
  const system = nativeMatchMedia("(prefers-color-scheme: dark)");
  let preference = "system";
  let parentDark = system.matches;

  const queries = new Set<{
    query: string;
    target: EventTarget;
    list: MediaQueryList;
  }>();

  const originals = new WeakMap<CSSMediaRule, string>();

  const dark = () =>
    preference === "dark" || (preference === "system" && parentDark);

  const matches = (query: string) =>
    query.includes("dark") ? dark() : !dark();

  window.matchMedia = (query) => {
    if (!/prefers-color-scheme:\s*(?:dark|light)/u.test(query)) {
      return nativeMatchMedia(query);
    }

    const target = new EventTarget();

    const list: MediaQueryList = {
      addEventListener: target.addEventListener.bind(target),
      addListener: (listener: EventListener) =>
        target.addEventListener("change", listener),
      dispatchEvent: target.dispatchEvent.bind(target),
      get matches() {
        return matches(query);
      },
      media: query,
      onchange: null,
      removeEventListener: target.removeEventListener.bind(target),
      removeListener: (listener: EventListener) =>
        target.removeEventListener("change", listener),
    };

    queries.add({ list, query, target });

    return list;
  };

  const updateRules = (rules: CSSRuleList) => {
    for (const rule of rules) {
      if (rule instanceof CSSMediaRule) {
        const query = originals.get(rule) ?? rule.media.mediaText;

        if (/prefers-color-scheme/u.test(query)) {
          originals.set(rule, query);
          rule.media.mediaText = query.replaceAll(
            /\(prefers-color-scheme:\s*(?<scheme>dark|light)\)/gu,
            (_, scheme) =>
              (scheme === "dark") === dark()
                ? "(min-width: 0px)"
                : "(min-width: 1000000px)"
          );
        }
      }

      if (rule instanceof CSSGroupingRule) {
        updateRules(rule.cssRules);
      }
    }
  };

  const syncStyles = () => {
    for (const sheet of document.styleSheets) {
      try {
        updateRules(sheet.cssRules);
      } catch {
        /* A loading stylesheet is handled by its load event. */
      }
    }

    document.documentElement.style.colorScheme = dark() ? "dark" : "light";
  };

  const update = (next = preference, nextParent = parentDark) => {
    const previous = dark();
    preference = next;
    parentDark = nextParent;
    syncStyles();

    if (previous !== dark()) {
      for (const { query, target, list } of queries) {
        const event = new MediaQueryListEvent("change", {
          matches: matches(query),
          media: query,
        });

        target.dispatchEvent(event);
        list.onchange?.(event);
      }
    }
  };

  const observer = new MutationObserver(syncStyles);
  observer.observe(document.head, {
    characterData: true,
    childList: true,
    subtree: true,
  });
  document.addEventListener("load", syncStyles, true);
  // The embedding page resolves its saved appearance against the OS.
  system.addEventListener("change", () => {
    if (window.parent === window) {
      update(preference, system.matches);
    }
  });
  syncStyles();

  return {
    set: update,
    setParent: (value: boolean) => {
      update(preference, value);
    },
  };
};
