#if DEBUG

    import Foundation

    /// Bridges `DebugRouter.Handler` — `@Sendable (Request) -> Response`, synchronous, no async
    /// support, a contract owned by `MirrorCalKit` and left alone — to `@MainActor` async work.
    /// Safe specifically because `DebugBridge` always calls a handler from its own serial queue,
    /// never from the main thread: blocking that queue while the main actor runs the real work
    /// cannot deadlock, it can only be slow, which the timeout turns into a `504` instead of a
    /// wedged debug bridge.
    enum DebugBridgeSync {
        static func awaitMainActor<T: Sendable>(
            timeout: TimeInterval = 30, _ work: @escaping @MainActor () async -> T
        ) -> T? {
            let semaphore = DispatchSemaphore(value: 0)
            let box = ResultBox<T>()
            Task { @MainActor in
                box.value = await work()
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
            return box.value
        }
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

#endif
