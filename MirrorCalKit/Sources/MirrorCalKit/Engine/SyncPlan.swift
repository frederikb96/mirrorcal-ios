/// The output of `SyncEngine.plan` — a full description of what would change the destination
/// calendar, computed but not yet applied. Kept as data rather than executed inline so a plan can
/// be inspected and asserted on in a test with no store involved at all.
public struct SyncPlan: Sendable, Equatable {
    public enum DeletionReason: Sendable, Equatable {
        /// The stamp key this destination event carries no longer matches any current,
        /// non-cancelled, non-excluded source occurrence.
        case sourceNoLongerPresent
        /// More than one destination event carried the same stamp — itself a form of drift, and
        /// self-healed the same way any other drift is: by comparing against reality, not by
        /// trusting whichever copy happened to be found first.
        case duplicateStamp
        /// Produced only by `SyncEngine.resetPlan`, never by `plan`.
        case reset
    }

    public struct Update: Sendable, Equatable {
        public let destinationIdentifier: String
        public let content: MirrorContent
    }

    public struct Deletion: Sendable, Equatable {
        public let destinationIdentifier: String
        public let reason: DeletionReason
    }

    /// Two or more distinct *source* occurrences producing the same `MirrorStamp.key` — itself a
    /// form of drift, on the source side rather than the destination side. `SyncEngine` mirrors
    /// exactly one deterministic survivor (never zero, never both — see `desiredContent`) and
    /// records every collision here, the source-side counterpart to a destination-side
    /// `DeletionReason.duplicateStamp`, so a log can tell "ambiguous source data" apart from
    /// ordinary churn.
    public struct SourceCollision: Sendable, Equatable {
        public let key: String
        /// How many colliding source occurrences produced this key — always >= 2.
        public let count: Int

        public init(key: String, count: Int) {
            self.key = key
            self.count = count
        }
    }

    public var creations: [MirrorContent] = []
    public var updates: [Update] = []
    public var deletions: [Deletion] = []
    /// The full content of everything that already matched — not just a count — so a caller can
    /// rebuild a `SyncCache` from the plan alone without asking the engine again.
    public var unchanged: [MirrorContent] = []
    public var sourceCollisions: [SourceCollision] = []
    /// How many source occurrences this run could not mirror at all because
    /// `MirrorContent.mirroring(_:configuration:)` refused them — currently only an empty
    /// external identifier. Never silently absorbed into `unchanged` or dropped with no trace;
    /// see `MirrorContent.mirroring(_:configuration:)` for why refusing outright is safer than
    /// minting a stamp guaranteed not to survive its own round trip.
    public var unstampableSourceEvents: Int = 0
    /// How many destination events, before matching, carried a stamp with this run's own
    /// `SyncConfiguration.installationIdentifier` — what `CreationCircuitBreaker` compares
    /// `creations.count` against. Zero on a genuine first sync into an empty (or foreign-only)
    /// calendar, which is what lets the breaker tell that case apart from a runaway.
    public var existingOwnedByInstall: Int = 0

    public var isEmpty: Bool { creations.isEmpty && updates.isEmpty && deletions.isEmpty }
}
