import AppKit
import NaturalLanguage
import OSLog
import SwiftUI
@preconcurrency @unsafe import Translation
import WebKit

/// Translates a page's text nodes in place with the on-device Translation framework; a second
/// toggle restores the original text.
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
            guard let texts = try await webView.callAsyncJavaScript(Self.collectScript, contentWorld: Self.world) as? [String],
                  !texts.isEmpty else { return }

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
                    var batch = (ids: Array(texts.indices), texts: texts)
                    while true {
                        for start in stride(from: 0, to: batch.ids.count, by: Self.chunkSize) {
                            let range = start..<min(start + Self.chunkSize, batch.ids.count)
                            let chunk = try await Self.translate(batch.texts[range], ids: batch.ids[range], with: session)
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
        _ texts: ArraySlice<String>, ids: ArraySlice<Int>, with session: TranslationSession
    ) async throws -> (ids: [Int], texts: [String]) {
        let requests = zip(ids, texts).map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        let responses = try await session.translations(from: requests)
        return (responses.compactMap { $0.clientIdentifier.flatMap(Int.init) }, responses.map(\.targetText))
    }

    /// Collects the page's text, then watches for text the page adds or rewrites, which `nextScript` hands over in batches.
    private static let collectScript = """
    const skipped = "script, style, noscript, code, pre, textarea, kbd, samp, svg, [translate=no], .notranslate";
    const accepts = (node) => {
      const parent = node.parentElement;
      return !!parent && !parent.isContentEditable && !parent.closest(skipped) && /\\p{L}/u.test(node.nodeValue);
    };
    // Weak, so the nodes a page drops are freed: only those awaiting their translation are held.
    const state = { originals: new WeakMap(), ids: new WeakMap(), inflight: new Map(), pending: new Set(), nextId: 0, wake: null, timer: 0 };
    const track = (node) => {
      const id = state.nextId++;
      state.ids.set(node, id);
      state.inflight.set(id, node);
      state.pending.add(id);
      state.originals.set(node, node.nodeValue);
    };
    const collect = (root) => {
      if (root.nodeType === Node.TEXT_NODE) {
        if (!state.originals.has(root) && accepts(root)) track(root);
        return;
      }
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode: (node) => !state.originals.has(node) && accepts(node) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT
      });
      while (walker.nextNode()) track(walker.currentNode);
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
        if (record.type === "characterData") {
          if (!accepts(record.target)) continue;
          // A node rewritten many times in one batch is translated once, from its latest text.
          const node = record.target, id = state.ids.get(node);
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
    collect(document.body ?? document.documentElement);
    const texts = [...state.inflight.values()].map((node) => state.originals.get(node).trim());
    state.pending.clear();
    state.observer = new MutationObserver(state.observe);
    state.observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
    window.__liloTranslation = state;
    return texts;
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
    const walker = document.createTreeWalker(document.documentElement, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const original = state.originals.get(walker.currentNode);
      if (original !== undefined) walker.currentNode.nodeValue = original;
    }
    return true;
    """
}
