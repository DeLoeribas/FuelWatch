import Foundation

/// Looks up French towns and postcodes with the national address API (api-adresse.data.gouv.fr).
struct AddressService: Sendable {
    static let endpoint = URL(string: "https://api-adresse.data.gouv.fr/search/")!

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns towns matching `query`, which can be a name or a postcode.
    func searchTowns(_ query: String) async throws -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }

        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "type", value: "municipality"),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FuelWatchError.badResponse(http.statusCode)
        }
        return try Self.parse(data)
    }

    private struct Collection: Decodable {
        struct Feature: Decodable {
            struct Geometry: Decodable { let coordinates: [Double] }
            struct Properties: Decodable {
                let name: String
                let postcode: String?
                let context: String?
            }
            let geometry: Geometry
            let properties: Properties
        }
        let features: [Feature]
    }

    static func parse(_ data: Data) throws -> [Place] {
        try JSONDecoder().decode(Collection.self, from: data).features.compactMap { feature in
            let c = feature.geometry.coordinates
            guard c.count == 2 else { return nil }
            return Place(name: feature.properties.name,
                         postcode: feature.properties.postcode ?? "",
                         latitude: c[1],
                         longitude: c[0])
        }
    }
}
