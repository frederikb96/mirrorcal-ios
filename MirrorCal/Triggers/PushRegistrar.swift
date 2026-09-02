import MirrorCalKit
import UIKit
import UserNotifications

/// The Apple-only half of push: asks for permission, asks APNs for a device token, registers it
/// with the sidecar host from `SyncSettings`, and — the reason any of this exists — runs a sync
/// whenever a silent push wakes the app, with the trigger recorded as `.push` and the reason as
/// "silent push" in the log — a push that wakes the app but runs an indistinguishable "just a
/// sync" would leave no way to tell the push actually did its job.
///
/// A `UIApplicationDelegate` because there is no other way to receive a device token or a remote
/// notification — SwiftUI has no equivalent, and both callbacks are delivered to the app delegate
/// or nowhere. `@MainActor` on the whole type, matching `AppSyncEngine`: `BackgroundTasks` also
/// registers from here, in the one callback Apple documents as required before launch finishes.
@MainActor
final class MirrorCalAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BackgroundTasks.register()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        DebugLogBuffer.shared.append(.info, "push", "registered device token with APNs")
        Task { await SidecarRegistrar.register(deviceToken: token) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        DebugLogBuffer.shared.append(.error, "push", "APNs registration failed: \(error)")
    }

    /// The one payload shape that can reach a fully backgrounded app: Apple's `content-available`
    /// push, sent by the sidecar's ticker. `UIBackgroundModes` must declare `remote-notification`
    /// (`Config/Info.plist`) or this is never called at all — which reads as the sidecar not
    /// working rather than as a missing capability declaration.
    ///
    /// Not `nonisolated`: unlike `UNUserNotificationCenterDelegate`'s methods,
    /// `UIApplicationDelegate`'s are `@MainActor` in the SDK, so this inherits the class's own
    /// isolation directly and can call straight into `AppSyncEngine` with no extra hop.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let outcome = await AppSyncEngine.shared?.run(reason: "silent push", trigger: .push)
            completionHandler(outcome != nil ? .newData : .failed)
        }
    }

    /// Requests notification permission if not yet answered, and asks APNs for a token either
    /// way if already granted — a token may still be owed to the sidecar from a launch that had
    /// no network. Safe to call on every launch: the system prompt is one-shot regardless.
    static func requestAuthorizationIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [])) ?? false
            guard granted else { return }
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        case .authorized, .provisional:
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        default:
            break
        }
    }
}

/// The app side of the push sidecar's registration contract: `POST /api/register` with a bearer
/// shared secret and the hex device token, on every launch that already has permission — cheap,
/// idempotent, and how a token rotation reaches the server with no extra bookkeeping.
enum SidecarRegistrar {
    struct RegistrationFailed: Error, Sendable { let status: Int }

    static func register(deviceToken: String) async {
        guard let engine = AppSyncEngine.shared else { return }
        let settings = await engine.settings
        guard !settings.sidecarHost.isEmpty, let secret = SyncSecretStore.load(), !secret.isEmpty else {
            DebugLogBuffer.shared.append(
                .warning, "push", "no sidecar host or shared secret configured — token not sent")
            return
        }
        guard let url = URL(string: settings.sidecarHost)?.appendingPathComponent("api/register") else {
            DebugLogBuffer.shared.append(.error, "push", "sidecar host is not a valid URL: \(settings.sidecarHost)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["device_token": deviceToken])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw RegistrationFailed(status: status)
            }
            DebugLogBuffer.shared.append(.info, "push", "device token registered with sidecar")
        } catch {
            // A `401` here specifically means a wrong or unconfigured shared secret — surfaced
            // through the same log a person actually reads, since a silent failure here means
            // the phone quietly stops getting pushed with nothing telling anyone why.
            DebugLogBuffer.shared.append(.error, "push", "sidecar registration failed: \(error)")
        }
    }
}
