/// What happens to one copyable field — title, description, or location — on its way from the
/// source event to the mirrored one. This is the entire privacy model: rather than a fixed
/// "Busy only" mode plus an escape hatch, every copyable field gets the same three-way choice, so
/// "Busy only" is simply title `.replace("Busy")` with description and location both `.drop`.
///
/// Times, the all-day flag and availability are never subject to a policy — without them there
/// is no mirror at all, so they are always copied (and availability is separately degraded to
/// what the destination calendar supports; see `EventAvailability.degraded`).
public enum FieldPolicy: Sendable, Equatable {
    case copy
    case drop
    case replace(String)

    /// `nil` for `.drop`, the source value for `.copy`, the fixed text for `.replace` — this is
    /// the only place any of the three cases is interpreted, so a field policy can only ever mean
    /// one of these things everywhere it is used.
    public func apply(to value: String?) -> String? {
        switch self {
        case .copy: value
        case .drop: nil
        case .replace(let text): text
        }
    }
}
