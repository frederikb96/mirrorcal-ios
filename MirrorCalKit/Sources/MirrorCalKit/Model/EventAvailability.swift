/// Busy/free/tentative/unavailable, the one metadata field (besides the text fields) that
/// survives the mirror. `.unavailable` is Exchange's out-of-office — the field that turned out to
/// be the only reliable signal for "Abwesend" events in the Android investigation.
public enum EventAvailability: String, Sendable, Codable, CaseIterable, Equatable {
    case busy
    case free
    case tentative
    case unavailable

    /// iCalendar's `TRANSP` property has only two values, so a destination calendar that does not
    /// report support for the finer distinctions still needs *something* written. Anything other
    /// than `.free` degrades to `.busy` rather than being silently dropped — an out-of-office
    /// block that loses its distinct value should still block the hour, not vanish.
    public func degraded(supportedByDestination supported: Set<EventAvailability>) -> EventAvailability {
        if supported.contains(self) { return self }
        return self == .free ? .free : .busy
    }
}

/// Only `.cancelled` is ever meaningful downstream — Apple documents every other `EKEvent.status`
/// value as informational. A cancelled occurrence is filtered out before it ever reaches the
/// diff, the same way the Android app filtered at the query level.
public enum EventStatus: String, Sendable, Codable, Equatable {
    case confirmed
    case cancelled
}
