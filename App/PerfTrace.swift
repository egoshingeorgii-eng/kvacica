import Foundation
import os

/// A log file in the app's Documents that outlives the app, for reading back from a phone:
/// `xcrun devicectl device copy from --device <phone> --domain-type appDataContainer
///  --domain-identifier com.georgiiegoshin.srpski --source Documents/<name> --destination <name>`.
/// Lines are timestamped; past the limit it starts again, since what's wanted is the latest.
struct TraceFile: Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private static let limit = 400_000

    init(_ name: String) {
        url = URL.documentsDirectory.appending(path: name)
        queue = DispatchQueue(label: name)
    }

    func append(_ message: String) {
        let line = "\(Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))) \(message)\n"
        let url = url
        queue.async {
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int), size > Self.limit {
                try? manager.removeItem(at: url)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// How long the work behind a stall takes: a signpost interval for Instruments, and a line in
/// `Documents/perf.log` (see `TraceFile`; on the Mac inside the sandbox container) to compare
/// before and after.
enum Perf {
    private static let signposter = OSSignposter(subsystem: "com.georgiiegoshin.srpski", category: "perf")
    /// The Debug bench (`-perfBench`) keeps its own log, apart from everyday use.
    private static let file = TraceFile(ProcessInfo.processInfo.arguments.contains("-perfBench") ? "perf-bench.log" : "perf.log")

    static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            let took = start.duration(to: .now).components
            let ms = Double(took.seconds) * 1000 + Double(took.attoseconds) / 1e15
            file.append("\(name) \(String(format: "%.1f", ms)) ms")
        }
        return try work()
    }

    /// A plain line in the log, to mark where a run is.
    static func note(_ message: String) {
        file.append(message)
    }

    private static let counting = ProcessInfo.processInfo.arguments.contains("-perfBench")
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var windowStart = ContinuousClock.now

    /// How often a view's body runs, logged once a second; only in the bench (`-perfBench`).
    static func count(_ name: String) {
        guard counting else { return }
        counts[name, default: 0] += 1
        guard windowStart.duration(to: .now) >= .seconds(1) else { return }
        flushCounts()
    }

    /// Writes the bodies counted so far (the bench, at each step's end).
    static func flushCounts() {
        if !counts.isEmpty {
            file.append("bodies " + counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
        }
        counts = [:]
        windowStart = .now
    }
}
