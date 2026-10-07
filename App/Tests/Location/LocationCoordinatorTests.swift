// Lane: location
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The foreground start of the degraded While-Using mode (design 3.4): opening the app starts the drive there, and
// only there.

import RadaresCore
import XCTest
@testable import RadaresAnunciados

final class LocationCoordinatorTests: XCTestCase {
    func testTheSceneStartsADriveOnlyUnderWhileUsingWithWarningsOnFromIdle() {
        XCTAssertTrue(LocationCoordinator.foregroundDriveWanted(whenInUseOnly: true, wantsAlways: true, pausedToday: false, state: .idle))
        XCTAssertFalse(LocationCoordinator.foregroundDriveWanted(whenInUseOnly: false, wantsAlways: true, pausedToday: false, state: .idle), "under Always a foreground launch waits for the user or an intent")
        XCTAssertFalse(LocationCoordinator.foregroundDriveWanted(whenInUseOnly: true, wantsAlways: false, pausedToday: false, state: .idle), "warnings off")
        XCTAssertFalse(LocationCoordinator.foregroundDriveWanted(whenInUseOnly: true, wantsAlways: true, pausedToday: true, state: .idle), "Pausar hoy")
        XCTAssertFalse(LocationCoordinator.foregroundDriveWanted(whenInUseOnly: true, wantsAlways: true, pausedToday: false, state: .driving), "never over a drive")
        XCTAssertFalse(LocationCoordinator.foregroundDriveWanted(whenInUseOnly: true, wantsAlways: true, pausedToday: false, state: .paused(since: Date())), "a paused drive resumes on its own")
        XCTAssertFalse(LocationCoordinator.foregroundDriveWanted(whenInUseOnly: true, wantsAlways: true, pausedToday: false, state: .probing), "a probe decides on its own")
    }
}
