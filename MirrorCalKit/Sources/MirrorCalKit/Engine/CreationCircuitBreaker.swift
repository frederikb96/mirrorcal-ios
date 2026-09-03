/// Thrown by `SyncEngine.apply` instead of writing anything, when a plan looks like a runaway
/// rather than a real sync.
public enum SyncApplyError: Error, Sendable, Equatable {
    /// `creations` is large relative to `existingOwned` — the signature `EventKitStamp`'s own doc
    /// comment calls out as unverified without a device: if the stamp does not survive the round
    /// trip to the destination and back, every mirrored event loses its identity on the next
    /// read and gets recreated, forever, with nothing bounding it. A genuine first sync
    /// (`existingOwned == 0`) never trips this; neither does an ordinary bulk change on an
    /// established mirror, where `creations` stays small next to what is already there.
    case suspectedRunaway(creations: Int, existingOwned: Int)
}

/// The threshold `SyncEngine.apply` checks a plan against before writing anything to the
/// destination. Both numbers are deliberately conservative rather than tuned against a real
/// corpus — nothing here has been exercised against production data — because this exists to
/// catch a failure that would otherwise run unbounded, not to second-guess an ordinary sync.
public struct CreationCircuitBreaker: Sendable, Equatable {
    /// Below this, a burst is not "large" regardless of ratio — a five-event calendar doubling is
    /// noise, not a runaway.
    public var minimumCreations: Int
    /// How large `creations` has to be, relative to `existingOwned`, to read as a repeat of the
    /// same corpus rather than a real bulk change.
    public var ratioOfExisting: Double

    public init(minimumCreations: Int = 20, ratioOfExisting: Double = 0.5) {
        self.minimumCreations = minimumCreations
        self.ratioOfExisting = ratioOfExisting
    }

    /// `existingOwned == 0` never trips: there is nothing yet for the creations to be a repeat
    /// of, which is exactly the first-sync-into-an-empty-calendar case that must always work.
    func tripped(creations: Int, existingOwned: Int) -> Bool {
        guard existingOwned > 0, creations >= minimumCreations else { return false }
        return Double(creations) >= Double(existingOwned) * ratioOfExisting
    }
}
