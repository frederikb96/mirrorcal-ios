#if DEBUG

    import Foundation

    /// A small, reusable corpus of source-event shapes covering the cases that mattered most in
    /// the Android investigation and in EventKit's own documented edge cases. Shared between this
    /// package's own tests and the app target, which reuses it to seed a simulator run — one
    /// definition of "what a tricky calendar looks like" rather than one copy per consumer.
    ///
    /// `#if DEBUG` because seeding a simulator is a development-time need, never a production
    /// one, matching the convention already used for `Debug/`.
    public enum EventFixtures {

        public struct Case: Sendable {
            public let name: String
            public let source: [SourceEventInstance]

            public init(name: String, source: [SourceEventInstance]) {
                self.name = name
                self.source = source
            }
        }

        public static let recurringSeries = Case(
            name: "recurring series",
            source: (0..<4).map { offset in
                SourceEventInstance(
                    externalIdentifier: "series-team-sync",
                    occurrenceStart: date(
                        year: 2026, month: 6, day: 1 + offset * 7, hour: 10, timeZoneIdentifier: berlin),
                    occurrenceEnd: date(
                        year: 2026, month: 6, day: 1 + offset * 7, hour: 10, minute: 30, timeZoneIdentifier: berlin),
                    title: "Team Sync",
                    timeZoneIdentifier: berlin
                )
            }
        )

        /// Its own series, distinct from `recurringSeries` — sharing one would let the two cases'
        /// occurrences collide by stamp key once `EventFixtures.all` combines every case into one
        /// corpus, which is a real drift scenario in its own right but not what this case is for.
        /// Per Apple's documented shape, a detached occurrence keeps its series'
        /// `calendarItemExternalIdentifier` and is told apart only by its own occurrence start,
        /// here moved an hour later and retitled.
        public static let detachedOccurrence = Case(
            name: "detached occurrence",
            source: [
                SourceEventInstance(
                    externalIdentifier: "series-standup",
                    occurrenceStart: date(year: 2026, month: 6, day: 15, hour: 10, timeZoneIdentifier: berlin),
                    occurrenceEnd: date(
                        year: 2026, month: 6, day: 15, hour: 10, minute: 30, timeZoneIdentifier: berlin),
                    title: "Team Sync",
                    timeZoneIdentifier: berlin
                ),
                SourceEventInstance(
                    externalIdentifier: "series-standup",
                    occurrenceStart: date(year: 2026, month: 6, day: 22, hour: 11, timeZoneIdentifier: berlin),
                    occurrenceEnd: date(
                        year: 2026, month: 6, day: 22, hour: 11, minute: 30, timeZoneIdentifier: berlin),
                    title: "Team Sync (moved)",
                    timeZoneIdentifier: berlin
                ),
            ]
        )

        public static let cancelledOccurrence = Case(
            name: "cancelled occurrence",
            source: [
                SourceEventInstance(
                    externalIdentifier: "series-team-sync",
                    occurrenceStart: date(year: 2026, month: 6, day: 29, hour: 10, timeZoneIdentifier: berlin),
                    occurrenceEnd: date(
                        year: 2026, month: 6, day: 29, hour: 10, minute: 30, timeZoneIdentifier: berlin),
                    title: "Team Sync",
                    timeZoneIdentifier: berlin,
                    status: .cancelled
                )
            ]
        )

        public static let allDayEvent = Case(
            name: "all-day event",
            source: [
                SourceEventInstance(
                    externalIdentifier: "all-day-offsite",
                    occurrenceStart: date(year: 2026, month: 7, day: 10, hour: 0, timeZoneIdentifier: "UTC"),
                    occurrenceEnd: date(year: 2026, month: 7, day: 11, hour: 0, timeZoneIdentifier: "UTC"),
                    isAllDay: true,
                    title: "Offsite",
                    timeZoneIdentifier: nil
                )
            ]
        )

        /// Spans a real Europe/Berlin daylight-saving transition, found programmatically rather
        /// than hand-picked — a wrong guess at a transition date would make this fixture silently
        /// stop testing what its name says the moment the actual DST rules changed under it.
        public static let dstBoundaryEvent: Case = {
            let reference = date(year: 2026, month: 1, day: 1, hour: 0, timeZoneIdentifier: "UTC")
            let transition = TimeZone(identifier: berlin)!.nextDaylightSavingTimeTransition(after: reference)!
            return Case(
                name: "DST boundary",
                source: [
                    SourceEventInstance(
                        externalIdentifier: "dst-boundary",
                        occurrenceStart: transition.addingTimeInterval(-3600),
                        occurrenceEnd: transition.addingTimeInterval(3600),
                        title: "Across DST",
                        timeZoneIdentifier: berlin
                    )
                ]
            )
        }()

        public static let crossTimeZoneEvent = Case(
            name: "cross time zone",
            source: [
                SourceEventInstance(
                    externalIdentifier: "tokyo-call",
                    occurrenceStart: date(year: 2026, month: 6, day: 15, hour: 9, timeZoneIdentifier: "Asia/Tokyo"),
                    occurrenceEnd: date(year: 2026, month: 6, day: 15, hour: 10, timeZoneIdentifier: "Asia/Tokyo"),
                    title: "Conference call",
                    timeZoneIdentifier: "Asia/Tokyo"
                )
            ]
        )

        public static let longDescriptionEvent = Case(
            name: "long description",
            source: [
                SourceEventInstance(
                    externalIdentifier: "long-notes",
                    occurrenceStart: date(year: 2026, month: 8, day: 3, hour: 14, timeZoneIdentifier: berlin),
                    occurrenceEnd: date(year: 2026, month: 8, day: 3, hour: 15, timeZoneIdentifier: berlin),
                    title: "Quarterly review",
                    notes: String(repeating: "Agenda item. ", count: 200),
                    timeZoneIdentifier: berlin
                )
            ]
        )

        /// Its title matches nothing about the fixture itself — it only becomes meaningful once a
        /// test supplies a `SyncConfiguration` whose `excludedTitles` contains "Focus time".
        public static let excludedTitleEvent = Case(
            name: "excluded by title",
            source: [
                SourceEventInstance(
                    externalIdentifier: "focus-time",
                    occurrenceStart: date(year: 2026, month: 8, day: 4, hour: 9, timeZoneIdentifier: berlin),
                    occurrenceEnd: date(year: 2026, month: 8, day: 4, hour: 11, timeZoneIdentifier: berlin),
                    title: "Focus time",
                    timeZoneIdentifier: berlin
                )
            ]
        )

        public static let all: [Case] = [
            recurringSeries,
            detachedOccurrence,
            cancelledOccurrence,
            allDayEvent,
            dstBoundaryEvent,
            crossTimeZoneEvent,
            longDescriptionEvent,
            excludedTitleEvent,
        ]

        // MARK: - Private

        private static let berlin = "Europe/Berlin"

        private static func date(
            year: Int, month: Int, day: Int, hour: Int, minute: Int = 0, timeZoneIdentifier: String
        ) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
            let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
            return calendar.date(from: components)!
        }
    }

#endif
