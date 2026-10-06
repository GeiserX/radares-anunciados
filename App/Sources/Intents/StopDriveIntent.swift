// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Parar aviso de radares": ends the drive (design 3.1, drive end). Compiled into the app and the widget extension.

import AppIntents

public struct StopDriveIntent: AppIntent {
    public static let title: LocalizedStringResource = "Parar aviso de radares"

    public init() {}

    public func perform() async throws -> some IntentResult {
        fatalError("lane: surfaces")
    }
}
