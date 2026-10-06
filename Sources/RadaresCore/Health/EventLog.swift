// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Append-only JSONL, rotated at Thresholds.logMaxLines, exported with the share sheet (design 6).
// Stub: `append` is a no-op and `recent` is empty, not a fatalError, because the app logs on its launch path
// and the skeleton must launch in the simulator. EventLogTests covers the real thing.

import Foundation

public struct EventLog: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public mutating func append(_ e: LogEvent) {
        // lane: core
    }

    public func recent(_ n: Int) -> [LogEntry] {
        // lane: core
        []
    }
}
