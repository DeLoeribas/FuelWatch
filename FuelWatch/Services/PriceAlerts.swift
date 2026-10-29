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
