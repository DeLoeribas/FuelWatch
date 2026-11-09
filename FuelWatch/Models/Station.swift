import CoreLocation
import Foundation

/// A place the user picked as the centre of the search area.
struct Place: Codable, Hashable, Sendable {
    var name: String
    var postcode: String
    var latitude: Double
    var longitude: Double

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

/// One station's price for one fuel.
struct StationPrice: Identifiable, Equatable, Sendable {
    let stationID: Int
    let address: String
    let town: String
    let postcode: String
    let latitude: Double
    let longitude: Double
    let price: Double
    let updated: Date?
    /// Distance from the search centre, in kilometres.
    let distance: Double

    var id: Int { stationID }

    /// Apple Maps link that drops a pin at the station.
    var mapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: "\(address), \(town)"),
        ]
        return components?.url
    }
}

/// A station that has temporarily run out of one fuel.
struct StationShortage: Identifiable, Equatable, Sendable {
    let stationID: Int
    let address: String
    let town: String
    let latitude: Double
    let longitude: Double
    /// When the station reported the fuel as out of stock.
    let since: Date?
    /// Distance from the search centre, in kilometres.
    let distance: Double

    var id: Int { stationID }

    var mapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: "\(address), \(town)"),
        ]
        return components?.url
    }
}

/// The result of one refresh for one fuel.
struct FuelReport: Equatable, Sendable {
    let fuel: FuelType
    /// Cheapest stations first.
    let cheapest: [StationPrice]
    let average: Double?
    let stationCount: Int
    /// Stations in the area that are temporarily out of this fuel, closest first.
    var shortages: [StationShortage] = []

    var bestPrice: Double? { cheapest.first?.price }
}
