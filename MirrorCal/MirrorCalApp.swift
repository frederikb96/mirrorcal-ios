import EventKit
import MirrorCalKit
import SwiftUI

@main
struct MirrorCalApp: App {
    @UIApplicationDelegateAdaptor(MirrorCalAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// `--mirrorcal-fixtures` on the launch command line — how a simulator with no calendar
    /// accounts at all (every CI runner) still gets realistic, populated screens to screenshot.
    /// `#if DEBUG` because `CommandLine.arguments` parsing for this only matters in the fixture
    /// workflow, which never ships.
    static let isFixtureMode: Bool = {
        #if DEBUG
            return CommandLine.arguments.contains("--mirrorcal-fixtures")
        #else
            return false
        #endif
    }()

    private static let eventStore = EKEventStore()

    @State private var engine = AppSyncEngine(store: MirrorCalApp.eventStore, fixtureMode: MirrorCalApp.isFixtureMode)
    private let changeObserver = CalendarChangeObserver()

    #if DEBUG
        /// Held for the app's lifetime; a listener that goes out of scope stops listening.
        private static let debugBridge = DebugBridge(router: DebugRoutes.make())
    #endif

    init() {
        #if DEBUG
            Self.debugBridge.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine)
                #if DEBUG
                    .environment(AppScreenTracker.shared)
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                changeObserver.start()
                // Idempotent and safe on every call (see its own doc comment) — this is the only
                // place it is called at all, which is what makes it run on an ordinary launch
                // (this fires as the app first becomes active) and again whenever the sidecar
                // host or secret is filled in after enabling, since that just means backgrounding
                // and returning to the app once.
                Task { await MirrorCalAppDelegate.requestAuthorizationIfNeeded() }
                Task { _ = await engine.run(reason: "foreground activation", trigger: .foreground) }
            case .background:
                changeObserver.stop()
                BackgroundTasks.scheduleRefresh()
                BackgroundTasks.scheduleProcessing()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
