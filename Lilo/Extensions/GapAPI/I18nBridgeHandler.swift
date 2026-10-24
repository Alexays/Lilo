import NaturalLanguage

/// Gap API handler for `chrome.i18n.detectLanguage`, which WebKit omits, backed by
/// NLLanguageRecognizer. Answers Chrome's shape: up to three languages with integer percentages.
@MainActor
final class I18nBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["i18n.detectLanguage"]

    func handle(_ call: GapCall) async -> Any? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(call.string("text") ?? "")
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3).sorted { $0.value > $1.value }
        let languages = hypotheses.compactMap { language, probability -> [String: Any]? in
            let percentage = Int((probability * 100).rounded())
            return percentage > 0 ? ["language": language.rawValue, "percentage": percentage] : nil
        }
        return ["isReliable": (hypotheses.first?.value ?? 0) >= 0.8, "languages": languages]
    }
}
