import AVFoundation

/// chrome.tts gap bridge over AVSpeechSynthesizer, which Chrome also speaks with on macOS. As in
/// Chrome's TtsController, every extension shares one queue and one pause state; an utterance's
/// progress goes to its own extension as the internal tts.onEvent, which its onEvent option hears.
@MainActor
final class TtsBridgeHandler: NSObject, GapHandler, AVSpeechSynthesizerDelegate {
    let gapActions: Set<String> = ["tts.speak", "tts.stop", "tts.pause", "tts.resume", "tts.isSpeaking", "tts.getVoices"]

    private struct Utterance {
        let speech: AVSpeechUtterance
        let enqueue: Bool
        let desiredEventTypes: Set<String>
        /// The calling context's key for its onEvent; nil when it passed none, so no event is sent.
        let srcId: Int?
        let extensionId: String
        weak var registry: ProfileExtensionRegistry?

        var key: String? { registry.map { "\($0.profileId)/\(extensionId)" } }
    }

    private struct Voice {
        let name: String
        let voice: AVSpeechSynthesisVoice
    }

    // Chrome's voice event types on macOS, in its order.
    private static let voiceEventTypes = ["start", "end", "word", "pause", "resume"]

    private let registriesProvider: () -> [ProfileExtensionRegistry]
    private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()
    private var current: Utterance?
    private var queue: [Utterance] = []
    private var paused = false
    private var lastCharIndex = 0
    /// Loaded on first use, dropped when the system's voices change.
    private var voices: [Voice]?
    nonisolated(unsafe) private var observers: [Any] = []

    init(registriesProvider: @escaping () -> [ProfileExtensionRegistry]) {
        self.registriesProvider = registriesProvider
        super.init()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.voices = nil
                    for registry in self.registriesProvider() {
                        registry.emitGapEvent("tts", "onVoicesChanged", args: [], requiredPermission: "tts")
                    }
                }
            },
            // An unloaded extension's speech ends with it.
            center.addObserver(forName: .extensionDidUnload, object: nil, queue: .main) { [weak self] note in
                guard let profileId = note.userInfo?["profileId"] as? UUID, let extensionId = note.userInfo?["extensionId"] as? String else { return }
                MainActor.assumeIsolated { self?.drop("\(profileId)/\(extensionId)") }
            }
        ]
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func handle(_ call: GapCall) async -> Any? {
        switch call.action {
        case "tts.speak":
            return await speak(call)
        case "tts.stop":
            stop(extensionId: call.extensionId)
        case "tts.pause":
            pause()
        case "tts.resume":
            resume()
        case "tts.isSpeaking":
            return isSpeaking
        case "tts.getVoices":
            return await loadVoices().map { voice -> [String: Any] in
                ["voiceName": voice.name, "lang": voice.voice.language, "remote": false, "eventTypes": Self.voiceEventTypes]
            }
        default:
            break
        }
        return nil
    }

    private var isSpeaking: Bool { current != nil || synthesizer.isSpeaking }

    // MARK: - Queue (TtsControllerImpl)

    private func speak(_ call: GapCall) async -> Any? {
        let text = call.string("utterance") ?? ""
        let options = call.payload["options"] as? [String: Any] ?? [:]
        let number = { (key: String) in (options[key] as? NSNumber)?.doubleValue }
        if text.utf8.count > 32768 { return BridgeError("Utterance length is too long.") }
        let lang = options["lang"] as? String ?? ""
        if !lang.isEmpty, lang.range(of: "^[A-Za-z]{2,8}([-_][A-Za-z0-9]{1,8})*$", options: .regularExpression) == nil {
            return BridgeError("Invalid lang.")
        }
        if let rate = number("rate"), !(0.1...10).contains(rate) { return BridgeError("Invalid rate.") }
        if let pitch = number("pitch"), !(0...2).contains(pitch) { return BridgeError("Invalid pitch.") }
        if let volume = number("volume"), !(0...1).contains(volume) { return BridgeError("Invalid volume.") }

        // Chrome strips SSML only from a document whose root is <speak>; AVSpeechUtterance parses it.
        let speech = (text.contains("<?xml") ? AVSpeechUtterance(ssmlRepresentation: text) : nil) ?? AVSpeechUtterance(string: text)
        speech.voice = Self.matchingVoice(
            in: await loadVoices(),
            name: options["voiceName"] as? String ?? "",
            lang: lang,
            requiredEventTypes: options["requiredEventTypes"] as? [String] ?? []
        )
        if let rate = number("rate") {
            // Chrome's mapping: below 1 scales the default rate, above it spreads 1...4 over the rest of the range.
            let excess = min(Float(rate) - 1, 3) / 3
            speech.rate = rate < 1 ? Float(rate) * AVSpeechUtteranceDefaultSpeechRate
                : AVSpeechUtteranceDefaultSpeechRate + excess * (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceDefaultSpeechRate)
        }
        if let pitch = number("pitch") { speech.pitchMultiplier = Float(pitch) }
        if let volume = number("volume") { speech.volume = Float(volume) }

        let utterance = Utterance(
            speech: speech,
            enqueue: options["enqueue"] as? Bool ?? false,
            desiredEventTypes: Set(options["desiredEventTypes"] as? [String] ?? []),
            srcId: (call.payload["srcId"] as? NSNumber)?.intValue,
            extensionId: call.extensionId,
            registry: call.registry
        )
        if paused && !utterance.enqueue {
            stopAll()
            queue.append(utterance)
            paused = true
        } else if paused || (isSpeaking && utterance.enqueue) {
            queue.append(utterance)
        } else {
            stopAll()
            speakNow(utterance)
        }
        return nil
    }

    private func speakNow(_ utterance: Utterance) {
        current = utterance
        lastCharIndex = 0
        synthesizer.speak(utterance.speech)
    }

    private func speakNext() {
        guard !paused, current == nil, !queue.isEmpty else { return }
        speakNow(queue.removeFirst())
    }

    private func stopAll() {
        stopCurrent()
        clearQueue()
    }

    /// Chrome stops the current utterance only for its own extension, but then empties the whole queue.
    private func stop(extensionId: String) {
        paused = false
        if let current, current.extensionId != extensionId { return }
        stopAll()
    }

    private func stopCurrent() {
        paused = false
        guard let utterance = current else { return }
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        send(utterance, "interrupted")
    }

    private func clearQueue() {
        let cancelled = queue
        queue = []
        cancelled.forEach { send($0, "cancelled") }
    }

    private func pause() {
        guard !paused else { return }
        paused = true
        guard let current else { return }
        synthesizer.pauseSpeaking(at: .immediate)
        send(current, "pause", charIndex: lastCharIndex)
    }

    private func resume() {
        guard paused else { return }
        paused = false
        guard let current else { return speakNext() }
        synthesizer.continueSpeaking()
        send(current, "resume", charIndex: lastCharIndex)
    }

    private func drop(_ key: String) {
        queue.removeAll { $0.key == key }
        if current?.key == key {
            stopCurrent()
            speakNext()
        }
    }

    /// TtsExtensionEventHandler: the event reaches the utterance's extension unless filtered out.
    private func send(_ utterance: Utterance, _ type: String, charIndex: Int? = nil, length: Int? = nil) {
        guard let srcId = utterance.srcId, let registry = utterance.registry,
              utterance.desiredEventTypes.isEmpty || utterance.desiredEventTypes.contains(type) else { return }
        var event: [String: Any] = ["type": type, "srcId": srcId, "isFinalEvent": ["end", "interrupted", "cancelled", "error"].contains(type)]
        event["charIndex"] = charIndex
        event["length"] = length
        registry.gapEvents.emit("tts", "onEvent", args: [event], to: [utterance.extensionId])
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.current, ObjectIdentifier(current.speech) == id else { return }
            self.send(current, "start", charIndex: 0)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        guard characterRange.length > 0, characterRange.location <= utterance.speechString.utf16.count else { return }
        Task { @MainActor in
            guard let current = self.current, ObjectIdentifier(current.speech) == id else { return }
            self.lastCharIndex = characterRange.location
            self.send(current, "word", charIndex: characterRange.location, length: characterRange.length)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance), length = utterance.speechString.utf16.count
        Task { @MainActor in
            guard let current = self.current, ObjectIdentifier(current.speech) == id else { return }
            self.current = nil
            self.send(current, "end", charIndex: length)
            self.speakNext()
        }
    }

    // MARK: - Voices

    /// Chrome's list: by name with the system default first, a shared name suffixed with its language.
    private func loadVoices() async -> [Voice] {
        if let voices { return voices }
        let loaded = await Task.detached { () -> [Voice] in
            var all = AVSpeechSynthesisVoice.speechVoices().sorted { $0.name < $1.name }
            if let preferred = Self.systemDefaultVoice(), let index = all.firstIndex(where: { $0.identifier == preferred.identifier }) {
                all.insert(all.remove(at: index), at: 0)
            }
            let counts = Dictionary(all.map { ($0.name, 1) }, uniquingKeysWith: +)
            return all.map { voice in
                let language = Locale.autoupdatingCurrent.localizedString(forIdentifier: voice.language) ?? voice.language
                return Voice(name: counts[voice.name, default: 0] > 1 ? "\(voice.name) (\(language))" : voice.name, voice: voice)
            }
        }.value
        voices = loaded
        return loaded
    }

    /// The Spoken Content voice the user picked in System Settings, else the current language's.
    nonisolated private static func systemDefaultVoice() -> AVSpeechSynthesisVoice? {
        let selections = UserDefaults(suiteName: "com.apple.Accessibility")?.array(forKey: "SpokenContentDefaultVoiceSelectionsByLanguage")
        if let selections, selections.count > 1, let id = (selections[1] as? [String: Any])?["voiceId"] as? String,
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: nil)
    }

    /// TtsControllerImpl::GetMatchingVoice: a named voice must match; then the utterance's language,
    /// the required event types and the app's language score, the first voice winning ties.
    private static func matchingVoice(in voices: [Voice], name: String, lang: String, requiredEventTypes: [String]) -> AVSpeechSynthesisVoice? {
        let appLang = Locale.preferredLanguages.first ?? "en-US"
        let parts = { (tag: String) in tag.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init) }
        let localeScore = { (voiceLang: String, wanted: String, exact: Int, prefix: Int) -> Int in
            let voiceParts = parts(voiceLang), wantedParts = parts(wanted)
            guard let language = voiceParts.first, language == wantedParts.first else { return 0 }
            return voiceParts.count > 1 && voiceParts.dropFirst().first == wantedParts.dropFirst().first ? exact : prefix
        }
        let hasRequired = requiredEventTypes.allSatisfy(voiceEventTypes.contains)
        var best: (score: Int, voice: AVSpeechSynthesisVoice)?
        for voice in voices where name.isEmpty || voice.name == name {
            var score = localeScore(voice.voice.language, lang, 1024, 256) + localeScore(voice.voice.language, appLang, 8, 2)
            if !requiredEventTypes.isEmpty && hasRequired { score += 128 }
            if score > best?.score ?? -1 { best = (score, voice.voice) }
        }
        return best?.voice
    }
}
