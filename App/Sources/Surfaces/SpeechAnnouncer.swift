// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// AVAudioSession (.playback, .voicePrompt, duckOthers + interruptSpokenAudioAndMixWithOthers) and
// AVSpeechSynthesizer, es-ES (design 4.1). Per-utterance activation; the once-per-drive activation fallback sits
// behind one switch for the background-launch test in VERIFY.md.
//
// One utterance at a time. A radar warning that arrives while another warning speaks waits for it (one slot, the
// newest wins); a warning that arrives while "Fin de tramo" speaks cuts it; a "Fin de tramo" that arrives while
// anything speaks is dropped. Every utterance ends in one `speech` log row with the route, the activation error
// and whether it finished. `setActive` blocks for a noticeable time, so the session calls run on their own actor,
// never on the main thread.

import AVFAudio
import RadaresCore
import UIKit
import os

public enum SpeechOutcome: Sendable, Hashable {
    /// The session is active and the synthesizer started; `route` is the output port (CarAudio, BluetoothA2DPOutput, Speaker).
    case spoken(route: String)
    /// Waiting for the warning that is speaking now.
    case queued
    case skipped(reason: String)
    /// `setActive` (or `setCategory`) threw: a red Estado row, never a silent miss.
    case failed(setActiveError: String)

    public var sink: SinkOutcome {
        switch self {
        case .spoken(let route): SinkOutcome(sink: .speech, ok: true, detail: route)
        case .queued: SinkOutcome(sink: .speech, ok: true, detail: "queued")
        case .skipped(let reason): SinkOutcome(sink: .speech, ok: false, detail: reason)
        case .failed(let error): SinkOutcome(sink: .speech, ok: false, detail: error)
        }
    }
}

@MainActor
public final class SpeechAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    public static let shared = SpeechAnnouncer()

    public enum Utterance: Sendable {
        case warning
        /// "Fin de tramo": dropped when anything else is speaking.
        case exit
    }

    /// The one switch of design 4.1. `perUtterance` activates the session right before each sentence and releases
    /// it after; `oncePerDrive` activates it at drive start with `.mixWithOthers` and keeps it, toggling
    /// `.duckOthers` only around sentences, in case a cold background launch cannot activate a session.
    public enum Activation: String, Sendable {
        case perUtterance
        case oncePerDrive
    }

    /// UserDefaults key of the switch (also settable as a launch argument: `-speech.activation oncePerDrive`).
    public static let activationKey = "speech.activation"

    public var activation: Activation {
        get { UserDefaults.standard.string(forKey: Self.activationKey).flatMap(Activation.init(rawValue:)) ?? .perUtterance }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.activationKey) }
    }

    /// An es-ES voice is on the device (Estado's "Voz" row). The compact one ships with iOS.
    public static var spanishVoiceAvailable: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { $0.language == "es-ES" }
    }

    private struct Speaking {
        /// Nil while the session is being prepared.
        var id: ObjectIdentifier?
        var kind: Utterance
        var route: String
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let session = AudioSessionGate()
    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "speech")
    private var speaking: Speaking?
    private var pending: Phrase?
    /// The process has been in the foreground at least once: speech from it is `launchContext: foreground`.
    private var everForeground: Bool

    private override init() {
        everForeground = UIApplication.shared.applicationState != .background
        super.init()
        synthesizer.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc private func didBecomeActive() {
        everForeground = true
    }

    /// Starts speaking `phrase` and returns once it has started (or was queued, skipped or failed), without waiting
    /// for the end; the `speech` row is logged when it ends.
    public func speak(_ phrase: Phrase, as kind: Utterance = .warning) async -> SpeechOutcome {
        guard !phrase.spoken.isEmpty else { return .skipped(reason: "empty") }
        if let current = speaking {
            switch (kind, current.kind) {
            case (.exit, _):
                logger.info("dropped exit sentence behind another")
                return .skipped(reason: "busy")
            case (.warning, .exit):
                pending = phrase
                if current.id != nil { synthesizer.stopSpeaking(at: .immediate) }
                return .queued
            case (.warning, .warning):
                pending = phrase
                return .queued
            }
        }
        return await start(phrase, kind: kind)
    }

    /// Once-per-drive mode: take the session at the first fix of the drive. Does nothing in per-utterance mode.
    public func beginDrive() async {
        guard activation == .oncePerDrive else { return }
        if let error = await session.holdForDrive() {
            AppLog.shared.post(.speech(route: Self.route, setActiveError: error, finished: false, launchContext: launchContext))
            logger.error("drive session activation failed: \(error, privacy: .public)")
        }
    }

    /// Releases the drive's session (once-per-drive mode); a sentence still speaking finishes first.
    public func endDrive() async {
        await session.endDrive(releaseNow: speaking == nil)
    }

    // MARK: Private

    private var launchContext: LaunchContext {
        everForeground || UIApplication.shared.applicationState != .background ? .foreground : .background
    }

    private static var route: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "none"
    }

    private func start(_ phrase: Phrase, kind: Utterance) async -> SpeechOutcome {
        speaking = Speaking(id: nil, kind: kind, route: "")
        if let error = await session.prepare(activation) {
            speaking = nil
            AppLog.shared.post(.speech(route: Self.route, setActiveError: error, finished: false, launchContext: launchContext))
            logger.error("setActive failed: \(error, privacy: .public)")
            startPending()
            return .failed(setActiveError: error)
        }
        if kind == .exit, pending != nil {
            // A warning arrived while the session was being prepared for "Fin de tramo": the warning wins.
            speaking = nil
            startPending()
            return .skipped(reason: "busy")
        }
        let utterance = AVSpeechUtterance(string: phrase.spoken)
        utterance.voice = Self.voice()
        utterance.prefersAssistiveTechnologySettings = false
        let route = Self.route
        speaking = Speaking(id: ObjectIdentifier(utterance), kind: kind, route: route)
        synthesizer.speak(utterance)
        logger.info("speaking on \(route, privacy: .public)")
        return .spoken(route: route)
    }

    private func startPending() {
        guard let next = pending else { return }
        pending = nil
        Task { _ = await self.start(next, kind: .warning) }
    }

    private func ended(_ id: ObjectIdentifier, finished: Bool) async {
        guard let current = speaking, current.id == id else { return }
        speaking = nil
        logger.info("utterance ended on \(current.route, privacy: .public), finished \(finished)")
        AppLog.shared.post(.speech(route: current.route, setActiveError: nil, finished: finished, launchContext: launchContext))
        if pending != nil {
            startPending()
            return
        }
        if let error = await session.afterUtterance(activation), speaking == nil {
            logger.error("session release failed: \(error, privacy: .public)")
        }
    }

    /// es-ES, enhanced or premium when installed, else the compact voice that ships with iOS. English by phone locale.
    private static func voice() -> AVSpeechSynthesisVoice? {
        let language = Bundle.main.preferredLocalizations.first == "en"
            ? AVSpeechSynthesisVoice.currentLanguageCode()
            : "es-ES"
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    // MARK: AVSpeechSynthesizerDelegate

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in await self.ended(id, finished: true) }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in await self.ended(id, finished: false) }
    }
}

/// Every AVAudioSession call, serialised off the main thread. Each method returns an error description or nil.
private actor AudioSessionGate {
    private var driveSessionActive = false
    /// The drive ended while a sentence was speaking: release after it.
    private var driveEnded = false

    private var audio: AVAudioSession { AVAudioSession.sharedInstance() }

    /// Right before a sentence: duck music, pause spoken audio, and activate (per utterance) or make sure the
    /// drive's session is held (once per drive).
    func prepare(_ activation: SpeechAnnouncer.Activation) -> String? {
        do {
            if activation == .oncePerDrive, !driveSessionActive {
                try takeDriveSession()
            }
            try audio.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            if activation == .perUtterance {
                try audio.setActive(true)
            }
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    /// Right after a sentence: release the session (per utterance), or keep it with only `.mixWithOthers`.
    func afterUtterance(_ activation: SpeechAnnouncer.Activation) -> String? {
        do {
            if activation == .oncePerDrive, driveSessionActive, !driveEnded {
                try audio.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers])
            } else {
                driveSessionActive = false
                driveEnded = false
                try audio.setActive(false, options: .notifyOthersOnDeactivation)
            }
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func holdForDrive() -> String? {
        guard !driveSessionActive else { return nil }
        do {
            try takeDriveSession()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func endDrive(releaseNow: Bool) {
        guard driveSessionActive else { return }
        if releaseNow {
            driveSessionActive = false
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            driveEnded = true
        }
    }

    private func takeDriveSession() throws {
        try audio.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers])
        try audio.setActive(true)
        driveSessionActive = true
        driveEnded = false
    }

    private static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
