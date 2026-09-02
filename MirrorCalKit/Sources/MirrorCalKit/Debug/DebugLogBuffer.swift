import Foundation
#if canImport(os)
    import os
#endif

/// An in-memory ring of recent log lines, plus (on Apple platforms) a mirror into the unified
/// system log — the two audiences this serves need different reach. The debug bridge's `/log`
/// route and the in-app Log screen read the ring directly, in debug builds and in a shipped
/// TestFlight build alike, since a TestFlight build has no debugger attached and the Log screen's
/// share sheet is the only way a fault on Freddy's own phone ever reaches anyone. The unified-log
/// mirror is what lets that same fault show up in a sysdiagnose or Console session with no app
/// build present at all.
///
/// `log stream` from the host is the equivalent of `logcat` and works, but it only shows what
/// happens *while* it is attached. The ring keeps the recent past, so an agent — or Freddy — can
/// act and then ask what happened, which is the order things actually occur in.
///
/// Bounded on purpose: an unbounded buffer in a long-running session is a slow leak that gets
/// blamed on the app.
public final class DebugLogBuffer: @unchecked Sendable {

    public enum Level: String, Codable, Sendable, Comparable, CaseIterable {
        case debug, info, warning, error

        private var rank: Int {
            switch self {
            case .debug: 0
            case .info: 1
            case .warning: 2
            case .error: 3
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }

        #if canImport(os)
            var osLogType: OSLogType {
                switch self {
                case .debug: .debug
                case .info: .info
                case .warning: .default
                case .error: .error
                }
            }
        #endif
    }

    public struct Entry: Codable, Sendable {
        public let level: Level
        public let category: String
        public let message: String
        public let at: Date
    }

    public static let shared = DebugLogBuffer()

    private let capacity: Int
    private var entries: [Entry] = []
    private let lock = NSLock()

    #if canImport(os)
        // The app's own bundle id, read at the call site's runtime rather than duplicated as a
        // literal here — `log show`/Console filter on this exact subsystem string.
        private static let subsystem = Bundle.main.bundleIdentifier ?? "com.frederikberg.mirrorcal"
    #endif

    public init(capacity: Int = 500) {
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    public func append(_ level: Level, _ category: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(level: level, category: category, message: message, at: Date()))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        #if canImport(os)
            // Public, deliberately: this is diagnostic text (counts, trigger names, error
            // descriptions), never calendar content, and it exists specifically to be readable
            // from outside a running app.
            Logger(subsystem: Self.subsystem, category: category)
                .log(level: level.osLogType, "\(message, privacy: .public)")
        #endif
    }

    /// Newest last, so reading it top-to-bottom matches the order things happened.
    public func snapshot(minimumLevel: Level = .debug, limit: Int = 200) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        let filtered = entries.filter { $0.level >= minimumLevel }
        return Array(filtered.suffix(limit))
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
    }
}
