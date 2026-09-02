import Foundation
import MirrorCalKit

/// Atomic JSON persistence for `SyncCache` in Application Support — a plain file rather than
/// SwiftData or Core Data: the destination calendar is the only thing that has to be durable, so
/// losing this file costs one sync's worth of redundant hash recomputation and nothing else.
public enum SyncCacheFile {
    private static let filename = "sync-cache.json"

    private static func url() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return directory.appendingPathComponent(filename)
    }

    /// Falls back to `.empty` on any read or decode failure — a corrupt or missing cache is only
    /// ever a lost optimisation, matching `SyncCache.loading`'s own schema-mismatch handling.
    public static func load() -> SyncCache {
        guard let url = try? url(), let data = try? Data(contentsOf: url) else { return .empty }
        guard let decoded = try? JSONDecoder().decode(SyncCache.self, from: data) else { return .empty }
        return SyncCache.loading(schemaVersion: decoded.schemaVersion, hashesByStampKey: decoded.hashesByStampKey)
    }

    /// Writes to a temporary file first and replaces the real one, so a crash mid-write never
    /// leaves a half-written cache behind to be loaded next launch — the same shape every
    /// atomic-write recommendation for this platform takes.
    public static func save(_ cache: SyncCache) {
        guard let url = try? url(), let data = try? JSONEncoder().encode(cache) else { return }
        let temporary = url.appendingPathExtension("tmp")
        guard (try? data.write(to: temporary)) != nil else { return }
        _ = try? FileManager.default.replaceItem(
            at: url, withItemAt: temporary, backupItemName: nil, options: [], resultingItemURL: nil)
    }
}
