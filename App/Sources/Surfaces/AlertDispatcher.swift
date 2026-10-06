// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Every AlertEvent goes through here to speech, the Live Activity and the notification (design 4). A missing
// surface changes nothing upstream; the sink outcomes go to the log on every alert.

import RadaresCore

@MainActor
public final class AlertDispatcher {
    public static let shared = AlertDispatcher()

    /// The one setting: voice on/off.
    public var voiceEnabled = true

    private init() {}

    public func handle(_ event: AlertEvent) async {
        fatalError("lane: surfaces")
    }
}
