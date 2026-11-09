import Foundation
import UserNotifications

/// Decides which price changes deserve a notification.
enum PriceAlerts {
    /// Smallest drop, in euros per litre, that counts as a price drop.
    /// Prices move in steps of 0.001, so this catches any real drop while ignoring rounding noise.
    static let minimumDrop = 0.0005

    /// Returns the alert text for `report` compared with the previous refresh, or nil when nothing is worth telling.
    ///
    /// - Parameters:
    ///   - previous: Cheapest price at the previous refresh, if any.
    ///   - threshold: Optional "tell me below this price" value.
    ///   - notifyOnDrop: Whether any drop should be reported.
    static func message(for report: FuelReport, previous: Double?, threshold: Double?, notifyOnDrop: Bool) -> (title: String, body: String)? {
        guard let best = report.cheapest.first else { return nil }
        let price = best.price.formatted(.priceFormat)
        let place = "\(best.address), \(best.town)"

        // A threshold fires only when crossing it, so a low price doesn't notify on every refresh.
        if let threshold, best.price <= threshold, previous.map({ $0 > threshold }) ?? true {
            return ("\(report.fuel.displayName) kost nu \(price)",
                    "Onder je alertprijs van \(threshold.formatted(.priceFormat)), bij \(place).")
        }
        return notifyOnDrop ? dropMessage(for: report, previous: previous) : nil
    }

    /// Returns the alert text when the cheapest price for `report` is lower than `previous`, otherwise nil.
    static func dropMessage(for report: FuelReport, previous: Double?) -> (title: String, body: String)? {
        guard let best = report.cheapest.first, let previous, previous - best.price >= minimumDrop else { return nil }
        let drop = (previous - best.price).formatted(.priceFormat)
        return ("\(report.fuel.displayName) \(drop) goedkoper: \(best.price.formatted(.priceFormat))",
                "Het goedkoopst bij \(best.address), \(best.town).")
    }

    // MARK: - Shortages

    /// Identifies one shortage; the start date is included so a station running out again later counts as new.
    static func shortageKey(_ shortage: StationShortage, fuel: FuelType) -> String {
        "\(fuel.rawValue):\(shortage.stationID):\(shortage.since.map { Int($0.timeIntervalSince1970) } ?? 0)"
    }

    /// Per fuel, the shortages in `reports` whose key isn't in `known`, closest first.
    static func newShortages(in reports: [FuelReport], known: Set<String>) -> [(fuel: FuelType, shortages: [StationShortage])] {
        reports.compactMap { report in
            let new = report.shortages.filter { !known.contains(shortageKey($0, fuel: report.fuel)) }
            return new.isEmpty ? nil : (report.fuel, new)
        }
    }

    /// Alert text for stations that just ran out of `fuel`, or nil when there are none.
    static func shortageMessage(fuel: FuelType, shortages: [StationShortage]) -> (title: String, body: String)? {
        guard let closest = shortages.first else { return nil }
        let distance = closest.distance.formatted(.number.precision(.fractionLength(1)))
        if shortages.count == 1 {
            return ("\(fuel.displayName) is op bij \(closest.town)",
                    "\(closest.address), \(closest.town) (\(distance) km) heeft geen \(fuel.displayName) meer.")
        }
        let towns = shortages.prefix(4).map(\.town).formatted(.list(type: .and))
        let more = shortages.count > 4 ? " en nog \(shortages.count - 4) stations" : ""
        return ("\(fuel.displayName) is op bij \(shortages.count) stations",
                "Geen \(fuel.displayName) meer in \(towns)\(more). Het dichtstbij is \(closest.town) (\(distance) km).")
    }

    /// Asks for permission to show notifications; returns whether it was granted.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}

extension FormatStyle where Self == FloatingPointFormatStyle<Double>.Currency {
    /// Fuel prices are quoted per litre with three decimals.
    static var priceFormat: Self {
        .currency(code: "EUR").precision(.fractionLength(3))
    }
}
