import Foundation

/// Availability of stock Hermes creation options on the selected connection.
enum AgentProfileCreationCloneSupport: Equatable, Sendable {
    /// Native `profiles.create` accepts mutually exclusive `clone_from` and `no_skills`.
    case nativeBundleOnly
    case unavailable(String)

    var unavailableReason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}
