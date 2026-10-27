import AppKit
import NaturalLanguage
import OSLog
import SwiftUI
@preconcurrency import Translation
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
                    for start in stride(from: 0, to: texts.count, by: Self.chunkSize) {
                        let chunk = try await Self.translate(texts[start..<min(start + Self.chunkSize, texts.count)], with: session)
                        // The page navigated or was restored: the rest has nowhere to go.
                        guard let webView, try await webView.callAsyncJavaScript(
                            Self.applyScript,
                            arguments: ["ids": chunk.ids, "texts": chunk.texts],
                            contentWorld: Self.world
                        ) as? Bool == true else { return }
                    }
                } catch {
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

    nonisolated private static func translate(_ texts: ArraySlice<String>, with session: TranslationSession) async throws -> (ids: [Int], texts: [String]) {
        let requests = texts.indices.map { TranslationSession.Request(sourceText: texts[$0], clientIdentifier: String($0)) }
        let responses = try await session.translations(from: requests)
        return (responses.compactMap { $0.clientIdentifier.flatMap(Int.init) }, responses.map(\.targetText))
    }

    private static let collectScript = """
    const skip = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "CODE", "PRE", "TEXTAREA", "KBD", "SAMP", "SVG"]);
    const walker = document.createTreeWalker(document.body ?? document.documentElement, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const parent = node.parentElement;
        if (!parent || skip.has(parent.tagName.toUpperCase()) || parent.isContentEditable) return NodeFilter.FILTER_REJECT;
        if (parent.closest("[translate=no], .notranslate")) return NodeFilter.FILTER_REJECT;
        return /\\p{L}/u.test(node.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      }
    });
    const nodes = [], originals = [];
    while (walker.nextNode()) { nodes.push(walker.currentNode); originals.push(walker.currentNode.nodeValue); }
    window.__liloTranslation = { nodes, originals };
    return originals.map((text) => text.trim());
    """

    private static let applyScript = """
    const state = window.__liloTranslation;
    if (!state) return false;
    ids.forEach((id, i) => {
      const original = state.originals[id];
      state.nodes[id].nodeValue = original.match(/^\\s*/)[0] + texts[i] + original.match(/\\s*$/)[0];
    });
    return true;
    """

    private static let restoreScript = """
    const state = window.__liloTranslation;
    if (!state) return false;
    delete window.__liloTranslation;
    state.nodes.forEach((node, i) => { node.nodeValue = state.originals[i]; });
    return true;
    """
}
