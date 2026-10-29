import Foundation

/// The fuels published by the French government price feed (prix-carburants).
enum FuelType: String, CaseIterable, Codable, Identifiable, Sendable {
    case gazole, sp95, e10, sp98, e85, gplc

    var id: String { rawValue }

    /// Name shown in the UI, matching what French pumps display.
    var displayName: String {
        switch self {
        case .gazole: "Gazole"
        case .sp95: "SP95"
        case .e10: "E10"
        case .sp98: "SP98"
        case .e85: "E85"
        case .gplc: "GPLc"
        }
    }

    /// Name used by the feed in `carburants_indisponibles`.
    var feedName: String { displayName }

    /// Prefix of the per-fuel fields in the feed, e.g. `gazole_prix`, `gazole_maj`.
    var fieldPrefix: String { rawValue }

    /// Fuels tracked on first launch.
    static let defaultSelection: Set<FuelType> = [.gazole, .sp95, .e85, .gplc]
}
