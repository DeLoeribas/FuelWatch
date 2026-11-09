import CoreLocation
import Foundation

/// Errors from the price and address services.
enum FuelWatchError: LocalizedError {
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .badResponse(let status): "De server antwoordde met status \(status)."
        }
    }
}

/// Fetches fuel prices from the government open data feed
/// (data.economie.gouv.fr, "prix des carburants en France, flux instantané v2").
struct PriceService: Sendable {
    static let endpoint = URL(string: "https://data.economie.gouv.fr/api/explore/v2.1/catalog/datasets/prix-des-carburants-en-france-flux-instantane-v2/records")!

    /// Prices older than this are ignored: some stations stop reporting and keep a stale price.
    static let maxPriceAgeDays = 7
    /// Shortages that started longer ago than this are ignored: some stations never clear a "temporary" shortage.
    static let maxShortageAgeDays = 14
    /// At most this many shortages are fetched per fuel.
    static let shortageLimit = 20

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches a report for every fuel in `fuels`, in parallel.
    func reports(for fuels: [FuelType], around place: Place, radiusKm: Int, limit: Int = 5) async throws -> [FuelReport] {
        try await withThrowingTaskGroup(of: FuelReport.self) { group in
            for fuel in fuels {
                group.addTask { try await report(for: fuel, around: place, radiusKm: radiusKm, limit: limit) }
            }
            var reports: [FuelReport] = []
            for try await report in group { reports.append(report) }
            return fuels.compactMap { fuel in reports.first { $0.fuel == fuel } }
        }
    }

    /// Fetches the cheapest stations and the area average for one fuel.
    func report(for fuel: FuelType, around place: Place, radiusKm: Int, limit: Int) async throws -> FuelReport {
        let filter = Self.filter(for: fuel, around: place, radiusKm: radiusKm)
        let p = fuel.fieldPrefix

        async let stationsData = get([
            "where": filter,
            "select": "id,adresse,ville,cp,geom,\(p)_prix,\(p)_maj",
            "order_by": "\(p)_prix asc",
            "limit": String(limit),
        ])
        async let statsData = get([
            "where": filter,
            "select": "avg(\(p)_prix) as average, count(*) as stations",
            "limit": "1",
        ])

        async let shortageData = get([
            "where": Self.shortageFilter(for: fuel, around: place, radiusKm: radiusKm),
            "select": "id,adresse,ville,geom,\(p)_rupture_debut",
            "order_by": "\(p)_rupture_debut desc",
            "limit": String(Self.shortageLimit),
        ])

        let stations = try Self.parseStations(try await stationsData, fuel: fuel, from: place)
        let stats = try Self.parseStats(try await statsData)
        let shortages = try Self.parseShortages(try await shortageData, fuel: fuel, from: place)
        return FuelReport(fuel: fuel, cheapest: stations, average: stats.average, stationCount: stats.count,
                          shortages: shortages)
    }

    // MARK: - Query building

    /// The ODSQL filter for stations within the radius that currently sell `fuel`.
    static func filter(for fuel: FuelType, around place: Place, radiusKm: Int) -> String {
        let p = fuel.fieldPrefix
        let point = "POINT(\(place.longitude) \(place.latitude))"
        return [
            "within_distance(geom, geom'\(point)', \(radiusKm)km)",
            "\(p)_prix is not null",
            "\(p)_maj >= now(days=-\(maxPriceAgeDays))",
            "not carburants_indisponibles = '\(fuel.feedName)'",
        ].joined(separator: " and ")
    }

    /// The ODSQL filter for stations within the radius that recently ran out of `fuel`.
    static func shortageFilter(for fuel: FuelType, around place: Place, radiusKm: Int) -> String {
        let p = fuel.fieldPrefix
        let point = "POINT(\(place.longitude) \(place.latitude))"
        return [
            "within_distance(geom, geom'\(point)', \(radiusKm)km)",
            "\(p)_rupture_type = 'temporaire'",
            "\(p)_rupture_debut >= now(days=-\(maxShortageAgeDays))",
        ].joined(separator: " and ")
    }

    private func get(_ parameters: [String: String]) async throws -> Data {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FuelWatchError.badResponse(http.statusCode)
        }
        return data
    }

    // MARK: - Parsing

    private struct Page<Record: Decodable>: Decodable {
        let results: [Record]
    }

    private struct Geometry: Decodable {
        let lon: Double
        let lat: Double
    }

    /// A station record; the price fields are named after the fuel, so they're read dynamically.
    private struct StationRecord: Decodable {
        let id: Int
        let adresse: String?
        let ville: String?
        let cp: String?
        let geom: Geometry?
        let values: [String: Double]
        /// The `_maj` and `_rupture_debut` date fields, by field name.
        let dates: [String: String]

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            id = try c.decode(Int.self, forKey: Key(stringValue: "id"))
            adresse = try c.decodeIfPresent(String.self, forKey: Key(stringValue: "adresse"))
            ville = try c.decodeIfPresent(String.self, forKey: Key(stringValue: "ville"))
            cp = try c.decodeIfPresent(String.self, forKey: Key(stringValue: "cp"))
            geom = try c.decodeIfPresent(Geometry.self, forKey: Key(stringValue: "geom"))
            var values: [String: Double] = [:]
            var dates: [String: String] = [:]
            for key in c.allKeys {
                if key.stringValue.hasSuffix("_prix") {
                    values[key.stringValue] = try c.decodeIfPresent(Double.self, forKey: key)
                } else if key.stringValue.hasSuffix("_maj") || key.stringValue.hasSuffix("_rupture_debut") {
                    dates[key.stringValue] = try c.decodeIfPresent(String.self, forKey: key)
                }
            }
            self.values = values
            self.dates = dates
        }
    }

    private struct StatsRecord: Decodable {
        let average: Double?
        let stations: Int
    }

    static func parseStations(_ data: Data, fuel: FuelType, from place: Place) throws -> [StationPrice] {
        let page = try JSONDecoder().decode(Page<StationRecord>.self, from: data)
        let dateParser = ISO8601DateFormatter()
        let p = fuel.fieldPrefix
        return page.results.compactMap { record in
            guard let price = record.values["\(p)_prix"], let geom = record.geom else { return nil }
            let distance = place.location.distance(from: CLLocation(latitude: geom.lat, longitude: geom.lon)) / 1000
            return StationPrice(
                stationID: record.id,
                address: record.adresse?.localizedCapitalized ?? "",
                town: record.ville?.localizedCapitalized ?? "",
                postcode: record.cp ?? "",
                latitude: geom.lat,
                longitude: geom.lon,
                price: price,
                updated: record.dates["\(p)_maj"].flatMap { dateParser.date(from: $0) },
                distance: distance
            )
        }
    }

    /// Parses shortage records, closest station first.
    static func parseShortages(_ data: Data, fuel: FuelType, from place: Place) throws -> [StationShortage] {
        let page = try JSONDecoder().decode(Page<StationRecord>.self, from: data)
        let dateParser = ISO8601DateFormatter()
        return page.results.compactMap { record -> StationShortage? in
            guard let geom = record.geom else { return nil }
            return StationShortage(
                stationID: record.id,
                address: record.adresse?.localizedCapitalized ?? "",
                town: record.ville?.localizedCapitalized ?? "",
                latitude: geom.lat,
                longitude: geom.lon,
                since: record.dates["\(fuel.fieldPrefix)_rupture_debut"].flatMap { dateParser.date(from: $0) },
                distance: place.location.distance(from: CLLocation(latitude: geom.lat, longitude: geom.lon)) / 1000
            )
        }
        .sorted { $0.distance < $1.distance }
    }

    static func parseStats(_ data: Data) throws -> (average: Double?, count: Int) {
        let page = try JSONDecoder().decode(Page<StatsRecord>.self, from: data)
        guard let first = page.results.first else { return (nil, 0) }
        return (first.average, first.stations)
    }
}
