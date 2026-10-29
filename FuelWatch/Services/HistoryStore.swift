import Foundation

/// One recorded refresh result for one fuel.
struct PricePoint: Codable, Equatable, Sendable {
    let date: Date
    let fuel: FuelType
    let cheapest: Double
    let average: Double?
    /// Identifies the search area, so history from another town or radius isn't mixed in.
    let areaKey: String
}

/// The cheapest price of one day.
struct DailyPrice: Identifiable, Equatable, Sendable {
    let day: Date
    let cheapest: Double
    var id: Date { day }
}

/// Persists price history as JSON in Application Support.
actor HistoryStore {
    /// History older than this is dropped.
    static let retentionDays = 365

    private let fileURL: URL
    private var points: [PricePoint] = []
    private var loaded = false

    init(fileURL: URL = HistoryStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "FuelWatch", directoryHint: .isDirectory)
            .appending(path: "history.json")
    }

    /// Area key for a centre and radius; coordinates are rounded so tiny differences don't split history.
    static func areaKey(for place: Place, radiusKm: Int) -> String {
        String(format: "%.3f,%.3f,%d", place.latitude, place.longitude, radiusKm)
    }

    /// Appends new points, prunes old ones and saves.
    func record(_ newPoints: [PricePoint]) throws {
        try loadIfNeeded()
        let cutoff = Date.now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        points = (points + newPoints).filter { $0.date >= cutoff }
        try save()
    }

    /// The most recent point for `fuel` in `areaKey`.
    func latest(for fuel: FuelType, areaKey: String) throws -> PricePoint? {
        try loadIfNeeded()
        return points.last { $0.fuel == fuel && $0.areaKey == areaKey }
    }

    /// The cheapest price per day for the last `days` days, oldest first.
    func daily(for fuel: FuelType, areaKey: String, days: Int, calendar: Calendar = .current) throws -> [DailyPrice] {
        try loadIfNeeded()
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: .now)) ?? .distantPast
        return Self.dailyMinimums(points.filter { $0.fuel == fuel && $0.areaKey == areaKey && $0.date >= start },
                                  calendar: calendar)
    }

    static func dailyMinimums(_ points: [PricePoint], calendar: Calendar = .current) -> [DailyPrice] {
        Dictionary(grouping: points) { calendar.startOfDay(for: $0.date) }
            .compactMap { day, dayPoints in
                dayPoints.map(\.cheapest).min().map { DailyPrice(day: day, cheapest: $0) }
            }
            .sorted { $0.day < $1.day }
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        points = try decoder.decode([PricePoint].self, from: Data(contentsOf: fileURL))
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(points).write(to: fileURL, options: .atomic)
    }
}
