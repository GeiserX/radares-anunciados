// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// AVAudioSession (.playback, .voicePrompt, duckOthers + interruptSpokenAudioAndMixWithOthers) and
// AVSpeechSynthesizer, es-ES (design 4.1). Per-utterance activation; the once-per-drive activation fallback sits
// behind one switch for the background-launch test in VERIFY.md.

import AVFAudio
import RadaresCore

public enum SpeechOutcome: Sendable, Hashable {
    case spoken(route: String)
    case skipped(reason: String)
    case failed(setActiveError: String)
}

public final class SpeechAnnouncer {
    public init() {}

    public func speak(_ phrase: Phrase) async -> SpeechOutcome {
        fatalError("lane: surfaces")
    }
}
