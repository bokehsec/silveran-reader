#if os(iOS)
import AVFoundation

/// Speaks or spells selected text for the selection toolbar's Speak and Spell items, which take
/// the place of the system's Speak Selection menu (that menu is removed with the rest of the
/// native callout; see `HighlightableWebView.buildMenu`).
///
/// Speech uses the person's Spoken Content voice and rate, and the system's own audio session so
/// it does not take over or stop the app's read-aloud playback session.
@MainActor
final class SelectionSpeaker {
    private let synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.usesApplicationAudioSession = false
        return synthesizer
    }()

    /// Starts speaking `text`, letter by letter when `spell` is set, replacing anything still
    /// being spoken.
    func speak(_ text: String, spell: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: spell ? Self.spelled(trimmed) : trimmed)
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The letters of a word separated so each is read on its own ("cat" → "c, a, t").
    static func spelled(_ word: String) -> String {
        word.map(String.init).joined(separator: ", ")
    }
}
#endif
