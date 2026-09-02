import MirrorCalKit
import SwiftUI

@main
struct MirrorCalApp: App {

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
            ContentView()
        }
    }
}

#if DEBUG

    /// The app's debug endpoints, `#if DEBUG` end to end.
    ///
    /// Reachable from the build host because a simulator shares the Mac's network stack:
    /// `curl 127.0.0.1:8765/health`.
    enum DebugRoutes {

        static func make() -> DebugRouter {
            var router = DebugRouter()

            router.register("GET", "/health") { _ in
                .encoding([
                    "status": "ok",
                    "bundle": Bundle.main.bundleIdentifier ?? "?",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                    "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
                ])
            }

            return router
        }
    }

#endif
