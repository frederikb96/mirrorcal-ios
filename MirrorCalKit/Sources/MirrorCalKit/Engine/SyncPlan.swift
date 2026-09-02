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

    public var creations: [MirrorContent] = []
    public var updates: [Update] = []
    public var deletions: [Deletion] = []
    /// The full content of everything that already matched — not just a count — so a caller can
    /// rebuild a `SyncCache` from the plan alone without asking the engine again.
    public var unchanged: [MirrorContent] = []

    public var isEmpty: Bool { creations.isEmpty && updates.isEmpty && deletions.isEmpty }
}
