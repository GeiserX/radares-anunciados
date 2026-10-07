// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Application Support/Radares (design 5.3): folder creation, completeUntilFirstUserAuthentication on every file and
// read back (protectionVerified), atomic feed replace with .bak, bundled snapshot copy, excluded from backup.

import Foundation
import RadaresCore
import os

public final class FileStore: Sendable {
    public static let shared = FileStore()

    public let folder: URL = AppPaths.folder

    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "files")

    private init() {}

    /// Atomic replace, previous file kept as feed.geojson.bak. Returns whether the protection attribute read back correctly.
    public func replaceFeed(with data: Data) throws -> Bool {
        fatalError("lane: app")
    }

    /// Stub: logs and returns so the skeleton launches in the simulator.
    public func copySnapshotIfNeeded() {
        logger.warning("lane: app: copySnapshotIfNeeded not implemented")
    }
}
