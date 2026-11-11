import WebKit
import XCTest
@testable import Lilo

@MainActor
final class PageTranslatorTests: XCTestCase {
    /// Italian text, so it differs from the test's language and the page is collected for translation.
    private static let page = """
    <p>Il gatto dorme sul divano tutto il giorno mentre la pioggia cade sulla città.</p>
    <pre><code><span>let gatto = dorme</span></code></pre>
    <svg><text>etichetta del grafico</text></svg>
    <ul id="feed"></ul>
    """

    /// Translation runs in its own world, which the test reads by name: the page cannot.
    private func originals(_ webView: WKWebView) async throws -> [String]? {
        try await webView.evaluateJavaScript("""
            (() => {
              const state = window.__liloTranslation;
              if (!state) return null;
              const texts = [];
              const read = (root) => {
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
                while (walker.nextNode()) {
                  const node = walker.currentNode;
                  for (const item of node.nodeType === Node.TEXT_NODE ? [node] : Object.values(state.attrs.get(node) ?? {})) {
                    const text = state.originals.get(item);
                    if (text !== undefined) texts.push(text.trim());
                  }
                  if (node.shadowRoot) read(node.shadowRoot);
                }
              };
              read(document.body);
              return texts;
            })()
            """, in: nil, contentWorld: .world(name: "lilo-translate")) as? [String]
    }

    func testTranslationSkipsCodeAndKeepsUpWithContentAddedLater() async throws {
        let webView = WKWebView()
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://news.example/"))
        let loaded = await pollUntil(timeout: 5) { (try? await webView.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('#feed')")) as? Bool == true }
        XCTAssertTrue(loaded)
        let translator = PageTranslator()

        await translator.toggle(in: webView)
        let collected = try await originals(webView)
        XCTAssertEqual(collected, ["Il gatto dorme sul divano tutto il giorno mentre la pioggia cade sulla città."],
                       "text nested in code or an SVG stays as written")

        _ = try await webView.evaluateJavaScript("feed.insertAdjacentHTML('beforeend', '<li>Un nuovo articolo appena arrivato</li>'); 0")
        let followed = await pollUntil(timeout: 5) { (try? await self.originals(webView))?.contains("Un nuovo articolo appena arrivato") == true }
        XCTAssertTrue(followed, "content a page adds while translated is translated too")

        await translator.toggle(in: webView)
        let restored = try await originals(webView)
        XCTAssertNil(restored)
    }

    func testTranslationCoversLabelsAndOpenShadowRootsAndRestoresThem() async throws {
        let webView = WKWebView()
        webView.loadHTMLString("""
            <p>Il gatto dorme sul divano tutto il giorno mentre la pioggia cade sulla città.</p>
            <input type="search" placeholder="Cerca nel sito" value="parola digitata">
            <input type="submit" value="Invia la richiesta">
            <button value="valore inviato" aria-label="Chiudi la finestra"></button>
            <img title="Fotografia del gatto" alt="Un gatto che dorme">
            <div id="card"></div>
            <div id="sealed"></div>
            <script>
              card.attachShadow({ mode: "open" }).innerHTML = "<span>Testo nel componente</span>";
              sealed.attachShadow({ mode: "closed" }).innerHTML = "<span>Testo sigillato</span>";
            </script>
            """, baseURL: URL(string: "https://news.example/"))
        let loaded = await pollUntil(timeout: 5) { (try? await webView.evaluateJavaScript("document.readyState === 'complete' && !!card.shadowRoot")) as? Bool == true }
        XCTAssertTrue(loaded)
        let translator = PageTranslator()

        await translator.toggle(in: webView)
        let collected = try await originals(webView)
        XCTAssertEqual(collected, [
            "Il gatto dorme sul divano tutto il giorno mentre la pioggia cade sulla città.",
            "Cerca nel sito", "Invia la richiesta", "Chiudi la finestra", "Fotografia del gatto", "Un gatto che dorme",
            "Testo nel componente"
        ], "labels and open shadow roots are collected; a typed value, a form value and a closed root are not")

        _ = try await webView.evaluateJavaScript("""
            document.querySelector("[type=search]").placeholder = "Trova un articolo";
            card.shadowRoot.firstChild.insertAdjacentHTML("afterend", "<b>Aggiunto nel componente</b>"); 0
            """)
        let followed = await pollUntil(timeout: 5) {
            let texts = try? await self.originals(webView)
            return texts?.contains("Trova un articolo") == true && texts?.contains("Aggiunto nel componente") == true
        }
        XCTAssertTrue(followed, "a label rewritten and shadow content added while translated are translated too")

        // Stands in for a translation landing: writes, then drops their records as the translator does.
        _ = try await webView.evaluateJavaScript("""
            document.querySelector("[type=search]").setAttribute("placeholder", "Find an article");
            document.querySelector("[type=submit]").setAttribute("value", "Send the request");
            card.shadowRoot.firstChild.firstChild.nodeValue = "Text in the component";
            window.__liloTranslation.observer.takeRecords(); 0
            """, in: nil, contentWorld: .world(name: "lilo-translate"))
        await translator.toggle(in: webView)
        let restored = try await webView.evaluateJavaScript("""
            [document.querySelector("[type=search]").placeholder, document.querySelector("[type=search]").value,
             document.querySelector("[type=submit]").value, card.shadowRoot.firstChild.textContent]
            """) as? [String]
        XCTAssertEqual(restored, ["Trova un articolo", "parola digitata", "Invia la richiesta", "Testo nel componente"])
    }
}
