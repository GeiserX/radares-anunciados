// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Append-only JSONL, rotated at Thresholds.logMaxLines, exported with the share sheet (design 6).
// One line per entry, `{"t": ISO 8601, "event": {...}}`. Writes never throw: a log that cannot be written is
// reported by the health screen through its absence, never by crashing the launch path.

import Foundation

public struct EventLog: Sendable {
    public let url: URL

    /// Lines in the file; counted on the first append, then kept.
    private var lineCount: Int?

    public init(url: URL) {
        self.url = url
    }

    public mutating func append(_ e: LogEvent) {
        append(e, at: Date())
    }

    public mutating func append(_ e: LogEvent, at date: Date) {
        guard let line = try? Self.encoder.encode(LogEntry(t: date, event: e)) else { return }
        if lineCount == nil { lineCount = Self.countLines(url) }
        if let count = lineCount, count >= Thresholds.logMaxLines {
            rotate()
        }
        var data = line
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                lineCount = (lineCount ?? 0) + 1
            } catch {
                return
            }
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try data.write(to: url, options: Self.writeOptions)
                lineCount = 1
            } catch {
                return
            }
        }
    }

    /// The newest `n` entries, oldest first. Lines that do not decode (an older schema) are skipped.
    public func recent(_ n: Int) -> [LogEntry] {
        guard n > 0, let data = try? Data(contentsOf: url) else { return [] }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if lines.count > n { lines = Array(lines.suffix(n)) }
        return lines.compactMap { try? Self.decoder.decode(LogEntry.self, from: $0) }
    }

    /// The whole file, for the share sheet.
    public func export() -> Data? {
        try? Data(contentsOf: url)
    }

    /// Number of lines on disk.
    public var count: Int {
        lineCount ?? Self.countLines(url)
    }

    /// Empties the log: the user can wipe the alert rows, which are the only ones with coordinates.
    public mutating func wipe() {
        try? FileManager.default.removeItem(at: url)
        lineCount = 0
    }

    /// Keeps the newest half of the lines so a rotation is not a second rotation one line later.
    private mutating func rotate() {
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let keep = lines.suffix(Thresholds.logMaxLines / 2)
        var out = Data()
        for line in keep {
            out.append(contentsOf: line)
            out.append(0x0A)
        }
        try? out.write(to: url, options: Self.writeOptions)
        lineCount = keep.count
    }

    private static func countLines(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
