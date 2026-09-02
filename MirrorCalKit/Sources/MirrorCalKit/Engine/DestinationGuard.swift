public enum DestinationGuardError: Error, Sendable, Equatable {
    case containsUnstampedEvents(count: Int)
}

/// The mirror image of the read-only source constraint, and the bigger destructive risk of the
/// two: the delete pass runs on every sync, and the destination is a real private calendar. This
/// is what makes "ownership by containment" true rather than assumed — once this has passed for a
/// calendar, every event ever found in it without a stamp is guaranteed to predate MirrorCal, not
/// merely believed to.
public enum DestinationGuard: Sendable {
    /// Called once, when a destination calendar is chosen in settings — never during an ordinary
    /// sync, and never on a schedule. `SyncEngine.plan` enforces the complementary half of this
    /// guarantee on every run: an unstamped event, or one stamped by a *different*
    /// `SyncConfiguration.installationIdentifier`, is never in the set a plan can reference at
    /// all, so nothing downstream of a passed check can later delete one anyway — which is also
    /// why this check does not need to reject a calendar merely because another installation's
    /// stamped events are already in it; a shared destination is exactly the case that guarantee
    /// exists for. This function exists so the *unstamped* mistake specifically is refused before
    /// it is even configured, with a number attached.
    public static func validateForConfiguration(existingEvents: [DestinationEvent]) -> Result<
        Void, DestinationGuardError
    > {
        let unstampedCount = existingEvents.filter { $0.stamp == nil }.count
        guard unstampedCount == 0 else {
            return .failure(.containsUnstampedEvents(count: unstampedCount))
        }
        return .success(())
    }
}
