import Foundation
import MirrorCalKit

/// Round-trips a `MirrorStamp` through `EKEvent.url`, which is what CalDAV's `URL` property
/// maps to. `MirrorStamp.encoded`/`decode` define the wire format (`mirrorcal:<id>:<epoch>`) but
/// say nothing about URL validity — `calendarItemExternalIdentifier` is opaque and not guaranteed
/// to contain only URL-safe characters, so this is where that gap is closed, independently of the
/// package: it is a storage detail of *this* destination, not something the engine's own stamp
/// type should have to know about.
///
/// ⚠️ Unverified without a device: whether `url` survives the CalDAV round trip to Nextcloud and
/// back is a real open question, with a `notes` trailer as a possible fallback if it does not.
/// This app does not yet implement that fallback. If `url` turns out not to survive, every
/// mirrored event loses its stamp on the next read and gets recreated rather than matched —
/// visible as every event duplicating on the sync after the first.
public enum EventKitStamp {

    private static let urlSafeCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:")

    /// `nil` only if percent-encoding itself fails, which `CharacterSet`-based encoding of an
    /// arbitrary `String` does not do in practice — checked anyway because `URL(string:)` is
    /// failable and a silently-dropped stamp is the one mistake this type exists to prevent.
    public static func url(for stamp: MirrorStamp) -> URL? {
        guard let encoded = stamp.encoded.addingPercentEncoding(withAllowedCharacters: urlSafeCharacters) else {
            return nil
        }
        return URL(string: encoded)
    }

    public static func stamp(from url: URL?) -> MirrorStamp? {
        guard let url else { return nil }
        let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        return MirrorStamp.decode(raw)
    }
}
