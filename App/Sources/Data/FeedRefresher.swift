// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// BGAppRefreshTask "io.github.geiserx.radares.refresh" (submit, handle, resubmit), the foreground and drive-start
// triggers through FeedRefreshPolicy, manual "Actualizar ahora" (design 5.1, 5.2).

@preconcurrency import BackgroundTasks
import Foundation
import RadaresCore
import UIKit
import os

@MainActor
public final class FeedRefresher {
    public static let shared = FeedRefresher()

    public static let taskIdentifier = "io.github.geiserx.radares.refresh"

    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "feed")
    private let policy = FeedRefreshPolicy()
    private var inFlight: Task<Void, Never>?

    private init() {}

    /// Registers the handler (must happen before launch finishes) and makes sure one request is pending.
    public func registerBackgroundTask() {
        // Handler on the main queue, so the task object never crosses an isolation boundary.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
            MainActor.assumeIsolated {
                FeedRefresher.shared.handle(task)
            }
        }
        if !registered {
            logger.error("BG task not registered: identifier missing from BGTaskSchedulerPermittedIdentifiers")
        }
        Task { await scheduleIfNotPending() }
    }

    /// The next run, `Thresholds.refreshBackgroundHours` from now. Only when none is pending: every launch would
    /// otherwise push the earliest date forward again, and a phone woken every few minutes would never run it.
    private func scheduleIfNotPending() async {
        let pending = await BGTaskScheduler.shared.pendingTaskRequests()
        guard !pending.contains(where: { $0.identifier == Self.taskIdentifier }) else { return }
        schedule()
    }

    private func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Thresholds.refreshBackgroundHours * 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The simulator always refuses (BGTaskSchedulerErrorDomain 1); a device refuses when Background App
            // Refresh is off, which Estado shows on its own row.
            logger.warning("BG task submit: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ task: BGTask) {
        schedule()
        let work = Task { @MainActor in
            await self.refreshIfNeeded(trigger: .background)
            await self.postHealthNoticeIfRed()
        }
        task.expirationHandler = {
            work.cancel()
            AppLog.shared.post(.bgTaskRan(expired: true))
            task.setTaskCompleted(success: false)
        }
        Task { @MainActor in
            await work.value
            guard !work.isCancelled else { return }
            AppLog.shared.post(.bgTaskRan(expired: false))
            task.setTaskCompleted(success: true)
        }
    }

    /// Design 6, "red while closed": a plain notice at most once per day (the Notifier keeps the clock) when Estado is red.
    private func postHealthNoticeIfRed() async {
        guard UIApplication.shared.applicationState != .active else { return }
        let inputs = await HealthMonitor().collect()
        guard let red = healthReport(inputs).first(where: { $0.status == .fail }) else { return }
        Notifier.shared.postHealthNotice("Radares: \(red.title.lowercased()), \(red.detail). Abre la app.")
    }

    /// Runs on every foreground (6 h), at drive start (24 h) and from the background task (6 h).
    public func refreshIfNeeded(trigger: FeedRefreshPolicy.Trigger) async {
        let meta = FileStore.shared.readMeta()
        guard policy.shouldRefresh(meta: meta, now: Date(), trigger: trigger) else {
            logger.info("refresh(\(trigger.rawValue, privacy: .public)): not due")
            return
        }
        await refresh()
    }

    /// "Actualizar ahora".
    public func refreshNow() async {
        await refresh()
    }

    /// One download at a time; a second caller waits for the one running.
    private func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await Self.download() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Conditional GET, validate, atomic replace, swap the in-memory store, log. A failure keeps the old file.
    nonisolated private static func download() async {
        let files = FileStore.shared
        var meta = files.readMeta()
        let now = Date()
        // Without a feed on disk an ETag would get a 304 and nothing to keep.
        let etag = FileManager.default.fileExists(atPath: AppPaths.feed.path) ? meta.etag : nil
        do {
            switch try await FeedClient().fetch(ifNoneMatch: etag) {
            case .notModified:
                meta.checkedAt = now
                meta.lastError = nil
                meta.consecutiveFailures = 0
                files.writeMeta(meta)
                AppLog.shared.post(.feedChecked(etag: etag, notModified: true))

            case let .updated(data, newEtag, lastModified):
                switch FeedValidator.validate(data) {
                case let .success(feed):
                    _ = try files.replaceFeed(with: feed.data)
                    CurrentFeed.shared.install(RadarStore(radars: feed.radars))
                    meta = FeedMeta(
                        etag: newEtag,
                        lastModified: lastModified,
                        fetchedAt: now,
                        checkedAt: now,
                        featureCount: feed.radars.count,
                        countsByKind: feed.countsByKind
                    )
                    files.writeMeta(meta)
                    AppLog.shared.post(.feedChecked(etag: newEtag, notModified: false))
                    AppLog.shared.post(.feedUpdated(count: feed.radars.count, etag: newEtag))
                case let .failure(error):
                    fail(&meta, "\(error)", at: now)
                }
            }
        } catch {
            fail(&meta, error.localizedDescription, at: now)
        }
    }

    nonisolated private static func fail(_ meta: inout FeedMeta, _ message: String, at now: Date) {
        meta.checkedAt = now
        meta.lastError = message
        meta.consecutiveFailures += 1
        FileStore.shared.writeMeta(meta)
        AppLog.shared.post(.feedFailed(error: message))
        Logger(subsystem: "io.github.geiserx.radares", category: "feed").error("refresh failed: \(message, privacy: .public)")
    }
}
