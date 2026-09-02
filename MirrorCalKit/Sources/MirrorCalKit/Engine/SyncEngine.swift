import Foundation

/// Computes what should change in the destination calendar, and applies it. Everything Freddy
/// asked for in row 42 lives in `plan`'s signature, not merely in its body: the function takes
/// only `source`, `destination`, and `configuration` — all three freshly observed or supplied by
/// the caller, none of them a remembered belief about a previous run. There is no cache parameter
/// to add one by accident later; a reviewer does not have to trust that `plan` ignores a cache, the
/// type says it cannot see one. That is what makes drift structurally unrepresentable rather than
/// merely avoided — see `DriftConvergenceTests` for the property this buys.
public struct SyncEngine: Sendable {
    public init() {}

    /// The whole diff: create what's missing, update what changed, delete what's gone, leave
    /// everything else alone. Reconciliation (row 29) is not a separate pass over this design —
    /// it is what this function already does on every ordinary call, because `destination` is
    /// always a fresh, full scan rather than a cached belief. A hand-deleted mirrored event is
    /// simply missing from `destination` on the next call, so it reappears in `creations`; an
    /// orphaned stamped event from an earlier install is simply present in `destination` with no
    /// local memory of it, so it matches normally by its own stamp. Nothing here special-cases
    /// either scenario — they are both just "the destination changed since it was last read,"
    /// which is the only kind of thing this function can ever see.
    public func plan(
        source: [SourceEventInstance],
        destination: [DestinationEvent],
        configuration: SyncConfiguration
    ) -> SyncPlan {
        var plan = SyncPlan()

        let desired = desiredContent(from: source, configuration: configuration)
        let desiredByKey = desired.byKey
        plan.sourceCollisions = desired.collisions
        plan.unstampableSourceEvents = desired.unstampableCount
        let observedByKey = collapsingDuplicates(
            groupedStampedDestinationEvents(destination, configuration: configuration), into: &plan)

        for (key, content) in desiredByKey {
            guard let existing = observedByKey[key] else {
                plan.creations.append(content)
                continue
            }
            if ContentHasher.hash(content) == ContentHasher.hash(observed: existing) {
                plan.unchanged.append(content)
            } else {
                plan.updates.append(.init(destinationIdentifier: existing.identifier, content: content))
            }
        }

        for (key, event) in observedByKey where desiredByKey[key] == nil {
            plan.deletions.append(.init(destinationIdentifier: event.identifier, reason: .sourceNoLongerPresent))
        }

        return sorted(plan)
    }

    /// Every stamped event *this configuration wrote*, unconditionally — not only the ones the
    /// current source would still produce, and including every copy of a duplicate stamp: reset
    /// does not need a survivor, it deletes all of them. "Ours" is decided by the exact same test
    /// `plan` uses (`event.stamp != nil` and `stamp.installationIdentifier ==
    /// configuration.installationIdentifier`), so reset and an ordinary sync agree on what
    /// belongs to this install by construction rather than by two implementations happening to
    /// match — a reset must never reach into another install's share of a shared destination
    /// calendar any more than an ordinary sync's delete pass may.
    public func resetPlan(
        destination: [DestinationEvent], configuration: SyncConfiguration = SyncConfiguration()
    ) -> [SyncPlan.Deletion] {
        destination
            .filter { $0.stamp?.installationIdentifier == configuration.installationIdentifier }
            .map { SyncPlan.Deletion(destinationIdentifier: $0.identifier, reason: .reset) }
            .sorted { $0.destinationIdentifier < $1.destinationIdentifier }
    }

    /// Stages every action in the plan and commits once — a whole plan reaches the destination as
    /// one round trip's worth of writes rather than one per event.
    public func apply(_ plan: SyncPlan, to store: any DestinationCalendarStore) throws -> SyncOutcome {
        for content in plan.creations {
            try store.stage(.create(content))
        }
        for update in plan.updates {
            try store.stage(.update(destinationIdentifier: update.destinationIdentifier, content: update.content))
        }
        for deletion in plan.deletions {
            try store.stage(.delete(destinationIdentifier: deletion.destinationIdentifier))
        }
        try store.commit()

        let duplicatesRemoved = plan.deletions.filter { $0.reason == .duplicateStamp }.count
        return SyncOutcome(
            created: plan.creations.count,
            updated: plan.updates.count,
            deleted: plan.deletions.count,
            unchanged: plan.unchanged.count,
            duplicatesRemoved: duplicatesRemoved,
            sourceCollisions: plan.sourceCollisions.count,
            unstampableSourceEvents: plan.unstampableSourceEvents
        )
    }

    /// Reads both sides fresh, plans, applies, and hands back a cache rebuilt entirely from this
    /// run's own plan. `cache` is accepted only so the type threads end to end for a caller that
    /// wants to persist one between launches — nothing in this function ever reads it to decide
    /// anything, which is the property `DriftConvergenceTests` exercises directly.
    @discardableResult
    public func synchronize(
        source: any SourceCalendarReading,
        destination: any DestinationCalendarStore,
        cache: SyncCache,
        configuration: SyncConfiguration,
        window: DateInterval
    ) throws -> (outcome: SyncOutcome, plan: SyncPlan, cache: SyncCache) {
        let sourceEvents = try source.events(in: window)
        let destinationEvents = try destination.events(in: window)
        let plan = plan(source: sourceEvents, destination: destinationEvents, configuration: configuration)
        let outcome = try apply(plan, to: destination)

        var rebuiltCache = SyncCache(schemaVersion: SyncCache.currentSchemaVersion)
        for content in plan.creations + plan.updates.map(\.content) + plan.unchanged {
            rebuiltCache.hashesByStampKey[content.stamp.key] = ContentHasher.hash(content)
        }
        return (outcome, plan, rebuiltCache)
    }

    // MARK: - Private

    /// Grouped by key first, exactly like `groupedStampedDestinationEvents` below, and for the
    /// same reason: two distinct source occurrences producing the same `MirrorStamp.key` is a
    /// real, reachable state — Apple documents `calendarItemExternalIdentifier` as not guaranteed
    /// unique per occurrence, and `MirrorStamp.key` truncates to the second — and an ordinary
    /// `result[key] = content` overwrite would silently keep whichever one the loop happened to
    /// visit last, with no trace the other ever existed. A collision is resolved the same way a
    /// destination-side duplicate is: one deterministic survivor (the lowest content hash, an
    /// arbitrary but stable tie-break — see `collapsingDuplicates`), recorded rather than
    /// silently dropped.
    private func desiredContent(
        from source: [SourceEventInstance],
        configuration: SyncConfiguration
    ) -> (byKey: [String: MirrorContent], collisions: [SyncPlan.SourceCollision], unstampableCount: Int) {
        let grouping = groupedSourceContent(from: source, configuration: configuration)
        var result: [String: MirrorContent] = [:]
        var collisions: [SyncPlan.SourceCollision] = []
        for (key, group) in grouping.byKey {
            result[key] = group.min { ContentHasher.hash($0) < ContentHasher.hash($1) }
            if group.count > 1 {
                collisions.append(.init(key: key, count: group.count))
            }
        }
        return (result, collisions, grouping.unstampableCount)
    }

    private func groupedSourceContent(
        from source: [SourceEventInstance],
        configuration: SyncConfiguration
    ) -> (byKey: [String: [MirrorContent]], unstampableCount: Int) {
        var result: [String: [MirrorContent]] = [:]
        var unstampableCount = 0
        for instance in source
        where instance.status != .cancelled && !configuration.excludedTitles.contains(instance.title) {
            guard let content = MirrorContent.mirroring(instance, configuration: configuration) else {
                unstampableCount += 1
                continue
            }
            result[content.stamp.key, default: []].append(content)
        }
        return (result, unstampableCount)
    }

    /// Only a *valid* stamp, written by *this configuration*, makes a destination event ours to
    /// reason about at all — an unstamped event, or one stamped by a different
    /// `SyncConfiguration.installationIdentifier`, never enters this map, and everything
    /// downstream in `plan` only ever sees what came out of here. That is the guard from row 38
    /// expressed as a filter that runs before `plan`'s own matching logic, extended to the same
    /// property across installations: two independent installs sharing one destination calendar
    /// can each only ever see, match, update or delete the events their own stamp identifies as
    /// theirs — an event from another install is, to this one, indistinguishable from any other
    /// hand-created event it must never touch.
    ///
    /// Grouped rather than collapsed to one entry per key: collapsing here, before duplicates can
    /// be detected, is exactly the bug this shape avoids — two destination events sharing a key
    /// would otherwise overwrite each other silently, with no trace that a second one ever
    /// existed for `collapsingDuplicates` to find and delete.
    private func groupedStampedDestinationEvents(
        _ destination: [DestinationEvent], configuration: SyncConfiguration
    ) -> [String: [DestinationEvent]] {
        var result: [String: [DestinationEvent]] = [:]
        for event in destination {
            guard let stamp = event.stamp, stamp.installationIdentifier == configuration.installationIdentifier else {
                continue
            }
            result[stamp.key, default: []].append(event)
        }
        return result
    }

    /// Two destination events sharing one stamp is itself a form of drift — self-healed the same
    /// way any other drift is, by comparing against reality: keep one deterministically, delete
    /// the rest.
    private func collapsingDuplicates(
        _ grouped: [String: [DestinationEvent]],
        into plan: inout SyncPlan
    ) -> [String: DestinationEvent] {
        var observedByKey: [String: DestinationEvent] = [:]
        for (key, group) in grouped {
            let sorted = group.sorted { $0.identifier < $1.identifier }
            observedByKey[key] = sorted[0]
            for extra in sorted.dropFirst() {
                plan.deletions.append(.init(destinationIdentifier: extra.identifier, reason: .duplicateStamp))
            }
        }
        return observedByKey
    }

    /// Dictionary iteration order is not defined, and a plan whose action order varies run to run
    /// makes both logs and tests harder to read for no benefit — sorting costs nothing here and
    /// buys determinism for both.
    private func sorted(_ plan: SyncPlan) -> SyncPlan {
        var result = plan
        result.creations.sort { $0.stamp.key < $1.stamp.key }
        result.updates.sort { $0.destinationIdentifier < $1.destinationIdentifier }
        result.deletions.sort { $0.destinationIdentifier < $1.destinationIdentifier }
        result.unchanged.sort { $0.stamp.key < $1.stamp.key }
        result.sourceCollisions.sort { $0.key < $1.key }
        return result
    }
}
