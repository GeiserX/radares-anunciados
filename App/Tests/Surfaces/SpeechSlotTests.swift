// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The one speaking slot has a way out of every state: the delegate's end, an audio interruption, a stale
// utterance with no end callback, the drive end. Without those one missed callback queues every later warning
// for the life of the process.

import XCTest
@testable import RadaresAnunciados

final class SpeechSlotTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let utterance = NSObject()

    func testTheDelegateEndFreesOnlyTheUtteranceItNames() {
        var slot = SpeechSlot()
        slot.claim(kind: .warning, now: t0)
        XCTAssertNotNil(slot.speaking)
        slot.started(id: ObjectIdentifier(utterance), kind: .warning, route: "CarAudio", now: t0)
        XCTAssertNil(slot.ended(id: ObjectIdentifier(NSObject())), "another utterance's end changes nothing")
        XCTAssertNotNil(slot.speaking)
        XCTAssertEqual(slot.ended(id: ObjectIdentifier(utterance))?.route, "CarAudio")
        XCTAssertNil(slot.speaking)
    }

    func testAnInterruptionFreesTheSlot() {
        var slot = SpeechSlot()
        XCTAssertNil(slot.interrupted(), "nothing was speaking")
        slot.started(id: ObjectIdentifier(utterance), kind: .warning, route: "Speaker", now: t0)
        XCTAssertEqual(slot.interrupted()?.kind, .warning)
        XCTAssertNil(slot.speaking)
    }

    func testAnUtteranceWithNoEndCallbackIsFreedAfterTheDeadline() {
        var slot = SpeechSlot()
        slot.started(id: ObjectIdentifier(utterance), kind: .warning, route: "Speaker", now: t0)
        XCTAssertNil(slot.releaseIfStale(now: t0.addingTimeInterval(SpeechSlot.maxUtteranceSeconds), synthesizerSpeaking: false), "inside the deadline it may still be speaking")
        XCTAssertNil(slot.releaseIfStale(now: t0.addingTimeInterval(SpeechSlot.maxUtteranceSeconds + 1), synthesizerSpeaking: true), "the synthesizer says it is speaking")
        XCTAssertEqual(slot.releaseIfStale(now: t0.addingTimeInterval(SpeechSlot.maxUtteranceSeconds + 1), synthesizerSpeaking: false)?.route, "Speaker")
        XCTAssertNil(slot.speaking, "freed: the next warning is spoken instead of queued forever")

        var preparing = SpeechSlot()
        preparing.claim(kind: .warning, now: t0)
        XCTAssertNil(preparing.releaseIfStale(now: t0.addingTimeInterval(60), synthesizerSpeaking: false), "a slot still preparing its session has no utterance to time out")
    }

    /// A claim made before the session was prepared is void once an interruption freed the slot or a later warning
    /// claimed it: the suspended start must not speak over the new holder.
    func testAClaimIsVoidAfterAnInterruptionOrALaterClaim() {
        var slot = SpeechSlot()
        let first = slot.claim(kind: .warning, now: t0)
        XCTAssertTrue(slot.holds(first))
        _ = slot.interrupted()
        XCTAssertFalse(slot.holds(first), "freed by the interruption")
        let second = slot.claim(kind: .warning, now: t0)
        XCTAssertFalse(slot.holds(first), "taken by a later claim")
        XCTAssertTrue(slot.holds(second))
    }

    func testTheDriveEndResetsTheSlot() {
        var slot = SpeechSlot()
        slot.started(id: ObjectIdentifier(utterance), kind: .exit, route: "Speaker", now: t0)
        slot.reset()
        XCTAssertNil(slot.speaking)
    }
}
