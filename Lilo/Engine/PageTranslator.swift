import AppKit
import NaturalLanguage
import OSLog
import SwiftUI
@preconcurrency @unsafe import Translation
import WebKit

/// Translates a page's text nodes and labelling attributes in place with the on-device Translation
/// framework; a second toggle restores the original text.
@MainActor
final class PageTranslator {
    private static let logger = Logger(liloCategory: "translation")
    // An isolated world, so the page can neither read the collected nodes nor tamper with them.
    private static let world = WKContentWorld.world(name: "lilo-translate")
    private static let chunkSize = 64

    @Observable @MainActor
    final class Model {
        var configuration: TranslationSession.Configuration?
        var work: ((TranslationSession) async -> Void)?
    }

    struct HostView: View {
        let model: Model
        var body: some View {
            // SwiftUI owns the session, which is what lets macOS prompt to download a missing language.
            Color.clear.translationTask(model.configuration) { session in await model.work?(session) }
        }
    }

    private let model = Model()
    /// Must sit in the window for the system download prompt to have somewhere to appear.
    let hostView: NSView

    init() {
        hostView = NSHostingView(rootView: HostView(model: model))
        hostView.frame = .zero
    }

    func toggle(in webView: WKWebView) async {
        do {
            if try await webView.callAsyncJavaScript(Self.restoreScript, contentWorld: Self.world) as? Bool == true { return }
            guard let page = try await webView.callAsyncJavaScript(Self.collectScript, contentWorld: Self.world) as? [String: Any],
                  let ids = page["ids"] as? [Int], let texts = page["texts"] as? [String], !texts.isEmpty else { return }

            let recognizer = NLLanguageRecognizer()
            recognizer.processString(texts.prefix(200).joined(separator: "\n"))
            let target = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
            guard let detected = recognizer.dominantLanguage?.rawValue,
                  Locale.Language(identifier: detected).languageCode != target.languageCode else {
                _ = try? await webView.callAsyncJavaScript(Self.restoreScript, contentWorld: Self.world)
                NSSound.beep()
                return
            }

            model.work = { [weak webView] session in
                do {
                    var batch = (ids: ids, texts: texts)
                    while true {
                        for start in stride(from: 0, to: batch.ids.count, by: Self.chunkSize) {
                            let range = start..<min(start + Self.chunkSize, batch.ids.count)
                            let chunk = try await Self.translate(batch.texts[range], ids: batch.ids[range], to: target, with: session)
                            // The page navigated or was restored: the rest has nowhere to go.
                            guard let webView, try await webView.callAsyncJavaScript(
                                Self.applyScript,
                                arguments: ["ids": chunk.ids, "texts": chunk.texts],
                                contentWorld: Self.world
                            ) as? Bool == true else { return }
                        }
                        // Waits, at no cost, for text the page adds; nil once the page is restored.
                        guard let webView, let next = try await webView.callAsyncJavaScript(Self.nextScript, contentWorld: Self.world) as? [String: Any],
                              let ids = next["ids"] as? [Int], let texts = next["texts"] as? [String], !Task.isCancelled else { return }
                        batch = (ids, texts)
                    }
                } catch {
                    // Another tab's translation took the session: this page keeps what it has.
                    guard !Task.isCancelled else { return }
                    Self.logger.error("page translation failed: \(error.localizedDescription, privacy: .public)")
                    _ = try? await webView?.callAsyncJavaScript(Self.restoreScript, contentWorld: Self.world)
                }
            }
            let configuration = TranslationSession.Configuration(source: Locale.Language(identifier: detected), target: target)
            if model.configuration == configuration {
                model.configuration?.invalidate()
            } else {
                model.configuration = configuration
            }
        } catch {
            Self.logger.error("page translation scripts failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func translate(
        _ texts: ArraySlice<String>, ids: ArraySlice<Int>, to target: Locale.Language, with session: TranslationSession
    ) async throws -> (ids: [Int], texts: [String]) {
        let recognizer = NLLanguageRecognizer()
        var translated: (ids: [Int], texts: [String]) = ([], [])
        var requests: [TranslationSession.Request] = []
        for (id, text) in zip(ids, texts) {
            // Shorter text is too little to tell its language from.
            if text.utf16.count >= 32 {
                recognizer.reset()
                recognizer.processString(text)
                // Already in the target language: it goes back as written, which also frees its node.
                if let language = recognizer.dominantLanguage?.rawValue,
                   Locale.Language(identifier: language).languageCode == target.languageCode {
                    translated.ids.append(id)
                    translated.texts.append(text)
                    continue
                }
            }
            requests.append(TranslationSession.Request(sourceText: text, clientIdentifier: String(id)))
        }
        guard !requests.isEmpty else { return translated }
        for response in try await session.translations(from: requests) {
            guard let id = response.clientIdentifier.flatMap(Int.init) else { continue }
            translated.ids.append(id)
            translated.texts.append(response.targetText)
        }
        return translated
    }

    /// Collects the page's text, then watches for text the page adds or rewrites, which `nextScript` hands over in batches.
    private static let collectScript = """
    const untranslated = "script, style, noscript, code, pre, kbd, samp, svg, [translate=no], .notranslate";
    // A textarea's text is what the user typed, its placeholder and title are the page's.
    const skipped = untranslated + ", textarea";
    const attributes = ["placeholder", "title", "alt", "aria-label", "value"];
    const labelled = "[placeholder], [title], [alt], [aria-label], input[value]";
    // Text sits in an element, straight in a shadow root, or in an attribute.
    const holder = (node) => node.ownerElement ?? node.parentElement ?? node.parentNode?.host;
    const accepts = (node) => {
      const parent = holder(node), owner = node.ownerElement;
      // A value is a label on a button only: on any other input it is what the user typed.
      if (owner && node.name === "value" && !(owner.localName === "input" && /^(button|submit|reset)$/.test(owner.type))) return false;
      return !!parent && !parent.isContentEditable && !parent.closest(owner ? untranslated : skipped) && /\\p{L}/u.test(node.nodeValue);
    };
    // Weak, so the nodes a page drops are freed: only those awaiting their translation are held.
    const state = {
      originals: new WeakMap(), ids: new WeakMap(), attrs: new WeakMap(), inflight: new Map(), pending: new Set(), nextId: 0, wake: null, timer: 0,
      watched: { childList: true, subtree: true, characterData: true, attributeFilter: attributes }
    };
    const track = (node) => {
      const id = state.nextId++;
      state.ids.set(node, id);
      state.inflight.set(id, node);
      state.pending.add(id);
      state.originals.set(node, node.nodeValue);
      // Nothing but a reference keeps an Attr's wrapper, and so its original, alive: its element holds it.
      const owner = node.ownerElement;
      if (owner) state.attrs.set(owner, { ...state.attrs.get(owner), [node.name]: node });
    };
    const collect = (root) => {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
      for (let node = root; node; node = walker.nextNode()) {
        if (node.nodeType === Node.TEXT_NODE) {
          if (!state.originals.has(node) && accepts(node)) track(node);
        } else if (node.nodeType === Node.ELEMENT_NODE) {
          if (node.matches(labelled)) {
            for (const name of attributes) {
              const attribute = node.getAttributeNode(name);
              if (attribute && !state.originals.has(attribute) && accepts(attribute)) track(attribute);
            }
          }
          // A MutationObserver stops at a shadow root: each open one is watched on its own.
          if (node.shadowRoot && !node.closest(skipped)) {
            state.observer.observe(node.shadowRoot, state.watched);
            collect(node.shadowRoot);
          }
        }
      }
    };
    // Bursts of changes (a feed page, a route) go out as one batch.
    state.flush = () => {
      if (!state.wake || !state.pending.size || state.timer) return;
      state.timer = setTimeout(() => {
        state.timer = 0;
        const ids = [...state.pending], wake = state.wake;
        state.pending.clear();
        state.wake = null;
        wake({ ids, texts: ids.map((id) => state.originals.get(state.inflight.get(id)).trim()) });
      }, 300);
    };
    state.observe = (records) => {
      for (const record of records) {
        if (record.type !== "childList") {
          const node = record.attributeName ? record.target.getAttributeNode(record.attributeName) : record.target;
          if (!node || !accepts(node)) continue;
          // A node rewritten many times in one batch is translated once, from its latest text.
          const id = state.ids.get(node);
          if (id === undefined) {
            track(node);
          } else {
            state.originals.set(node, node.nodeValue);
            state.inflight.set(id, node);
            state.pending.add(id);
          }
        } else {
          record.addedNodes.forEach(collect);
        }
      }
      state.flush();
    };
    state.observer = new MutationObserver(state.observe);
    collect(document.body ?? document.documentElement);
    // What is on screen goes out first: one pass of rect reads, and nothing left watching the scroll.
    const ids = [], below = [];
    for (const [id, node] of state.inflight) {
      const rect = holder(node).getBoundingClientRect();
      (rect.bottom > 0 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth ? ids : below).push(id);
    }
    for (const id of below) ids.push(id);
    state.pending.clear();
    state.observer.observe(document.documentElement, state.watched);
    window.__liloTranslation = state;
    return { ids, texts: ids.map((id) => state.originals.get(state.inflight.get(id)).trim()) };
    """

    private static let nextScript = """
    const state = window.__liloTranslation;
    if (!state) return null;
    return await new Promise((resolve) => { state.wake = resolve; state.flush(); });
    """

    private static let applyScript = """
    const state = window.__liloTranslation;
    if (!state) return false;
    state.observe(state.observer.takeRecords());
    ids.forEach((id, i) => {
      const node = state.inflight.get(id);
      if (!node) return;
      // A node rewritten since it went out keeps its place for the batch carrying its new text.
      if (!state.pending.has(id)) state.inflight.delete(id);
      const original = state.originals.get(node);
      node.nodeValue = original.match(/^\\s*/)[0] + texts[i] + original.match(/\\s*$/)[0];
    });
    // Its own writes are not the page's changes.
    state.observer.takeRecords();
    return true;
    """

    private static let restoreScript = """
    const state = window.__liloTranslation;
    if (!state) return false;
    delete window.__liloTranslation;
    state.observer.disconnect();
    clearTimeout(state.timer);
    state.wake?.(null);
    const restore = (root) => {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        const node = walker.currentNode;
        for (const item of node.nodeType === Node.TEXT_NODE ? [node] : Object.values(state.attrs.get(node) ?? {})) {
          const original = state.originals.get(item);
          if (original !== undefined) item.nodeValue = original;
        }
        if (node.shadowRoot) restore(node.shadowRoot);
      }
    };
    restore(document.documentElement);
    return true;
    """
}
