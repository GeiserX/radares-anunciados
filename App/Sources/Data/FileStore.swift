// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Application Support/Radares (design 5.3): folder creation, completeUntilFirstUserAuthentication on every file and
// read back (protectionVerified), atomic feed replace with .bak, bundled snapshot copy, excluded from backup.
// Also holds the decoded feed in memory (`CurrentFeed`), so every lane reads one RadarStore.

import Foundation
import RadaresCore
import Synchronization
import os

public final class FileStore: Sendable {
    public static let shared = FileStore()

    public let folder: URL = AppPaths.folder

    /// The protection class every file here gets: readable after the first unlock, also while locked. Not `.none`:
    /// iOS delivers no location events before the first unlock, so nothing needs the files before it.
    public static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    static let snapshotName = "feed-snapshot"

    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "files")
    private let prepared = Mutex(false)

    private init() {}

    /// Creates the folder with the protection attribute and excludes it from backup (the feed is re-downloadable).
    /// Cheap after the first call; called at launch and before every write.
    public func prepareFolder() {
        guard !prepared.withLock({ $0 }) else { return }
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: folder.path) {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: Self.protection])
            } else {
                try fm.setAttributes([.protectionKey: Self.protection], ofItemAtPath: folder.path)
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = folder
            try url.setResourceValues(values)
            prepared.withLock { $0 = true }
        } catch {
            logger.error("folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Atomic replace, previous file kept as feed.geojson.bak. Returns whether the protection attribute read back correctly.
    public func replaceFeed(with data: Data) throws -> Bool {
        prepareFolder()
        let fm = FileManager.default
        let incoming = folder.appending(path: "feed.geojson.new")
        try? fm.removeItem(at: incoming)
        try data.write(to: incoming, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if fm.fileExists(atPath: AppPaths.feed.path) {
            try? fm.removeItem(at: AppPaths.feedBackup)
            _ = try fm.replaceItemAt(
                AppPaths.feed,
                withItemAt: incoming,
                backupItemName: AppPaths.feedBackup.lastPathComponent,
                options: [.withoutDeletingBackupItem]
            )
        } else {
            try fm.moveItem(at: incoming, to: AppPaths.feed)
        }
        // replaceItemAt may carry the old file's attributes over; set the class explicitly on both, then read it back.
        for url in [AppPaths.feed, AppPaths.feedBackup] where fm.fileExists(atPath: url.path) {
            try? fm.setAttributes([.protectionKey: Self.protection], ofItemAtPath: url.path)
        }
        let ok = verifyProtection()
        AppLog.shared.post(.protectionVerified(ok: ok))
        return ok
    }

    /// Reads the protection attribute back from the folder and the feed: the one check that proves the store is
    /// readable while the phone is locked (shortcoming C).
    public func verifyProtection() -> Bool {
        let fm = FileManager.default
        let urls = [folder, AppPaths.feed].filter { fm.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return false }
        return urls.allSatisfy { url in
            let value = (try? fm.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType
            return value == Self.protection
        }
    }

    /// The bundled snapshot's generation time, from the sidecar `feed-snapshot.date` (ISO 8601).
    public var snapshotDate: Date? {
        guard let url = Bundle.main.url(forResource: Self.snapshotName, withExtension: "date"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return try? Date(text.trimmingCharacters(in: .whitespacesAndNewlines), strategy: .iso8601)
    }

    /// Copies the bundled snapshot in when no feed exists yet, so the first drive after install works offline.
    /// Returns true when it copied.
    @discardableResult
    public func copySnapshotIfNeeded() -> Bool {
        guard !FileManager.default.fileExists(atPath: AppPaths.feed.path) else { return false }
        guard let url = Bundle.main.url(forResource: Self.snapshotName, withExtension: "geojson") else {
            logger.error("no bundled snapshot")
            AppLog.shared.post(.feedFailed(error: "snapshot missing from the bundle"))
            return false
        }
        do {
            _ = try replaceFeed(with: Data(contentsOf: url))
            logger.info("snapshot copied")
            return true
        } catch {
            logger.error("snapshot copy: \(error.localizedDescription, privacy: .public)")
            AppLog.shared.post(.feedFailed(error: "snapshot copy: \(error.localizedDescription)"))
            return false
        }
    }

    // MARK: feed.meta.json

    public func readMeta() -> FeedMeta {
        guard let data = try? Data(contentsOf: AppPaths.feedMeta),
              let meta = try? JSONDecoder.radares.decode(FeedMeta.self, from: data)
        else { return FeedMeta() }
        return meta
    }

    public func writeMeta(_ meta: FeedMeta) {
        prepareFolder()
        do {
            let data = try JSONEncoder.radares.encode(meta)
            try data.write(to: AppPaths.feedMeta, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("meta: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension JSONEncoder {
    static var radares: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var radares: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The decoded feed every lane reads: the drive loop builds its `AlertEngine` from `CurrentFeed.shared.store`, the
/// map and the sources screen read it too. Loaded once per process from `feed.geojson` (design 3.3 step 4), swapped
/// in place after a validated download; a drive keeps the store it started with until it asks again.
public final class CurrentFeed: Sendable {
    public static let shared = CurrentFeed()

    private struct State {
        var store: RadarStore?
        var loading: Task<RadarStore?, Never>?
    }

    private let state = Mutex(State())
    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "feed")

    private init() {}

    /// The store as loaded now; nil before the first load finishes or when there is no feed at all.
    public var store: RadarStore? { state.withLock { $0.store } }

    /// Copies the bundled snapshot when needed, then decodes feed.geojson off the main thread. Safe to call from
    /// anywhere and any number of times: one load per process, later callers await the same one.
    @discardableResult
    public func loadIfNeeded() async -> RadarStore? {
        let task: Task<RadarStore?, Never> = state.withLock { state in
            if let loading = state.loading { return loading }
            let loading = Task.detached(priority: .utility) { () -> RadarStore? in
                Self.load()
            }
            state.loading = loading
            return loading
        }
        return await task.value
    }

    /// After a validated download: the new radars replace the old ones for every reader that asks from now on.
    public func install(_ store: RadarStore) {
        state.withLock { state in
            state.store = store
            state.loading = Task { store }
        }
    }

    private static func load() -> RadarStore? {
        let files = FileStore.shared
        files.prepareFolder()
        let copied = files.copySnapshotIfNeeded()
        let logger = Logger(subsystem: "io.github.geiserx.radares", category: "feed")
        guard let data = try? Data(contentsOf: AppPaths.feed) else {
            logger.error("no feed file")
            return nil
        }
        do {
            let store = try RadarStore.load(geojson: data)
            // A download that finished first already installed a newer store; keep it.
            shared.state.withLock { if $0.store == nil { $0.store = store } }
            var meta = files.readMeta()
            if copied || meta.featureCount == 0 {
                // A fresh install: the feed's age is the snapshot's, and no ETag, so the first download gets a body.
                if copied {
                    meta = FeedMeta(fetchedAt: files.snapshotDate)
                }
                meta.featureCount = store.count
                meta.countsByKind = store.countsByKind
                files.writeMeta(meta)
            }
            logger.info("feed loaded, \(store.count) radars")
            return store
        } catch {
            logger.error("feed decode: \(error.localizedDescription, privacy: .public)")
            AppLog.shared.post(.feedFailed(error: "decode: \(error.localizedDescription)"))
            return nil
        }
    }
}
