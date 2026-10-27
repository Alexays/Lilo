import CoreAudio
import WebKit

/// With headphones on, a page's microphone skips WebKit's echo cancellation: WebKit runs it through Apple's voice
/// processing, which cuts everything above 12 kHz and lowers the voice, and headphones leave no echo to cancel. When
/// the output leaves headphones, those tracks end so the page reopens the microphone with echo cancellation, as WebKit
/// does not apply the constraint to a live track.
@MainActor
final class MicrophoneBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let messageHandlerName = "liloMicrophone"

    var isEnabled: () -> Bool = { true }
    var usesHeadphones: () -> Bool = { MicrophoneBridge.defaultOutput().map(MicrophoneBridge.isHeadphones) ?? false }

    /// Pages holding a microphone track without echo cancellation, told when the output leaves headphones.
    private let rawPages = NSHashTable<WKWebView>.weakObjects()
    private var watchedOutput: AudioObjectID?
    private lazy var outputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.outputDidChange() }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        // Only the main frame's tracks are reachable when the output changes.
        guard message.frameInfo.isMainFrame, let webView = message.webView, isEnabled(), usesHeadphones() else { return (false, nil) }
        rawPages.add(webView)
        watch(Self.defaultOutput())
        return (true, nil)
    }

    func outputDidChange() {
        guard !usesHeadphones() else { return watch(Self.defaultOutput()) }
        for webView in rawPages.allObjects {
            webView.evaluateJavaScript(PageWorld.push("speakers"), in: nil, in: PageWorld.bridgeWorld)
        }
        rawPages.removeAllObjects()
        watch(nil)
    }

    /// Follows the default output and, as a wired jack switches the built-in output's data source, that device's.
    private func watch(_ output: AudioObjectID?) {
        guard output != watchedOutput else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var defaultAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        var sourceAddress = Self.address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
        if let watchedOutput {
            AudioObjectRemovePropertyListenerBlock(watchedOutput, &sourceAddress, .main, outputListener)
            if output == nil { AudioObjectRemovePropertyListenerBlock(system, &defaultAddress, .main, outputListener) }
        } else if output != nil {
            AudioObjectAddPropertyListenerBlock(system, &defaultAddress, .main, outputListener)
        }
        if let output { AudioObjectAddPropertyListenerBlock(output, &sourceAddress, .main, outputListener) }
        watchedOutput = output
    }

    nonisolated private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ empty: T) -> T? {
        var address = address(selector, scope)
        var value = empty
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    nonisolated private static func defaultOutput() -> AudioObjectID? {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
    }

    /// Headphones, a headset or the built-in jack. USB devices report USB Audio terminal types (0x302 headphones, 0x402 headset).
    nonisolated private static func isHeadphones(_ device: AudioObjectID) -> Bool {
        if value(device, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, UInt32(0)) == 0x6864_706E { return true } // 'hdpn'
        guard let stream = value(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, AudioObjectID(0)),
              let terminal = value(stream, kAudioStreamPropertyTerminalType, kAudioObjectPropertyScopeGlobal, UInt32(0)) else { return false }
        return terminal == kAudioStreamTerminalTypeHeadphones || terminal == 0x302 || terminal == 0x402
    }

    /// Asks for the microphone without echo cancellation when the page leaves the choice to the browser and native
    /// answers that the output is headphones; ends those tracks, as an unplugged microphone would, on `speakers`.
    static let pageModule = #"""
    function () {
      if (window !== window.top || !window.isSecureContext || typeof MediaDevices === 'undefined') return;
      const stop = MediaStreamTrack.prototype.stop, rawTracks = new Set();
      function choosesEchoCancellation(audio) {
        const value = audio.echoCancellation;
        return value === false || (value !== null && typeof value === 'object' && (value.exact === false || value.ideal === false));
      }
      const originals = lilo.methods(MediaDevices.prototype, {
        getUserMedia(constraints) {
          const audio = constraints && constraints.audio;
          // Chrome's capture ids (`mandatory`) and an explicit choice stay the page's.
          if (!audio || (typeof audio === 'object' && (audio.mandatory || choosesEchoCancellation(audio)))) return apply(originals.getUserMedia, this, arguments);
          const devices = this, args = arguments;
          return lilo.post('liloMicrophone', null).catch(() => false).then(raw => {
            if (!raw) return apply(originals.getUserMedia, devices, args);
            const options = assign({}, constraints, { audio: assign({}, audio === true ? {} : audio, { echoCancellation: false }) });
            return apply(originals.getUserMedia, devices, [options]).then(stream => {
              for (const track of rawTracks) if (track.readyState === 'ended') rawTracks.delete(track);
              for (const track of stream.getAudioTracks()) rawTracks.add(track);
              return stream;
            });
          });
        }
      });
      lilo.on('speakers', () => {
        for (const track of rawTracks) {
          if (track.readyState !== 'live') continue;
          apply(stop, track, []);
          apply(dispatch, track, [new NativeEvent('ended')]);
        }
        rawTracks.clear();
      });
    }
    """#
}
