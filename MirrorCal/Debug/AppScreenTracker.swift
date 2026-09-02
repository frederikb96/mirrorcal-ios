#if DEBUG

    import Foundation
    import Observation

    /// Tracks which tab is on screen and lets the debug bridge drive it — the CI screenshot step
    /// has no `idb` and no human, so `/navigate` is how it switches screens between shots, and
    /// `/screen` is what it asserts against before trusting the screenshot it is about to take.
    /// This is the "prefer a debug bridge over a screenshot" doctrine applied to navigation
    /// itself, not only to reading state.
    @MainActor
    @Observable
    final class AppScreenTracker {
        static let shared = AppScreenTracker()

        enum Screen: String, CaseIterable, Sendable {
            case status, configuration, log
        }

        var current: Screen = .status

        private init() {}
    }

#endif
