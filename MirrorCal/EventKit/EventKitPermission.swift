import EventKit
import Foundation

/// The four outcomes worth telling a person apart, collapsed from `EKAuthorizationStatus`.
///
/// `.writeOnly` is its own case rather than folded into `.denied`: it is a real grant, just not
/// one this app can use — a mirror has to read back its own writes to reconcile, so write-only
/// access is exactly as useless as no access, but saying so plainly is what tells someone to
/// re-grant rather than to keep waiting.
public enum CalendarAccessStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case writeOnly
    case denied
    /// An MDM profile withheld access outright. Distinct from `.denied` because the settings
    /// screen that resolves a denial does nothing here — there is no toggle on this device that
    /// grants it back.
    case restricted

    var canRead: Bool { self == .authorized }
}

/// Requests and reports calendar access. Thin on purpose — every decision about what to do with
/// the answer belongs to whatever called it, not to this type.
public enum EventKitPermission {

    public static func currentStatus() -> CalendarAccessStatus {
        map(EKEventStore.authorizationStatus(for: .event))
    }

    /// Shows the system prompt if `.notDetermined`, and does nothing otherwise — the prompt is
    /// one-shot per install, so calling this again once answered is always safe and never surprises
    /// anyone with a second dialog.
    @discardableResult
    public static func requestFullAccess(using store: EKEventStore) async -> CalendarAccessStatus {
        let before = currentStatus()
        guard before == .notDetermined else { return before }
        _ = try? await store.requestFullAccessToEvents()
        return currentStatus()
    }

    private static func map(_ status: EKAuthorizationStatus) -> CalendarAccessStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .authorized
        case .writeOnly: .writeOnly
        @unknown default: .denied
        }
    }
}
