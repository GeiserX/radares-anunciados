// Lane: frozen (orchestrator)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The one log every lane writes to, and the one folder every file lives in (design 5.3 and 6).
// Location writes location events, surfaces write sink events, app writes feed and health events; all through
// `AppLog.shared`. `EventLog` itself (append, rotate, export) is the core lane's.

import Foundation
import RadaresCore

/// `Application Support/Radares/` and the files in it. The app lane's `FileStore` creates the folder, sets the
/// protection attribute and excludes it from backup; everyone else only reads these URLs.
public enum AppPaths {
    public static let folder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Radares", directoryHint: .isDirectory)
    public static let feed = folder.appending(path: "feed.geojson")
    public static let feedBackup = folder.appending(path: "feed.geojson.bak")
    public static let feedMeta = folder.appending(path: "feed.meta.json")
    public static let passes = folder.appending(path: "passes.json")
    public static let events = folder.appending(path: "events.jsonl")
}

public actor AppLog {
    public static let shared = AppLog(url: AppPaths.events)

    private var log: EventLog

    init(url: URL) {
        log = EventLog(url: url)
    }

    public func append(_ event: LogEvent) {
        log.append(event)
    }

    public func recent(_ n: Int) -> [LogEntry] {
        log.recent(n)
    }

    /// Fire and forget, for synchronous contexts such as the launch path and delegate callbacks.
    public nonisolated func post(_ event: LogEvent) {
        Task { await self.append(event) }
    }
}
