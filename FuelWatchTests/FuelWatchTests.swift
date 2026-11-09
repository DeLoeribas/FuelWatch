import Foundation
import Testing
@testable import FuelWatch

private let dax = Place(name: "Dax", postcode: "40100", latitude: 43.71, longitude: -1.05)

private func station(_ price: Double) -> StationPrice {
    StationPrice(stationID: 1, address: "1 Rue Test", town: "Dax", postcode: "40100",
                 latitude: 43.7, longitude: -1.05, price: price, updated: nil, distance: 1)
}

private func report(_ prices: Double...) -> FuelReport {
    FuelReport(fuel: .gazole, cheapest: prices.map(station), average: nil, stationCount: prices.count)
}

@Suite("Price feed")
struct PriceServiceTests {
    @Test("Filter limits radius, fuel availability and price age")
    func filter() {
        let filter = PriceService.filter(for: .e85, around: dax, radiusKm: 20)
        #expect(filter.contains("within_distance(geom, geom'POINT(-1.05 43.71)', 20km)"))
        #expect(filter.contains("e85_prix is not null"))
        #expect(filter.contains("e85_maj >= now(days=-7)"))
        #expect(filter.contains("not carburants_indisponibles = 'E85'"))
    }

    @Test("Station records are parsed with distance and update date")
    func parseStations() throws {
        let json = """
        {"total_count": 1, "results": [{"id": 40100001, "adresse": "12 AVENUE GEORGES CLEMENCEAU", "ville": "DAX",
          "cp": "40100", "geom": {"lon": -1.05, "lat": 43.72}, "gplc_prix": 1.079, "gplc_maj": "2026-10-29T09:30:00+00:00"},
          {"id": 2, "adresse": "no price", "ville": "Dax", "cp": "40100", "geom": {"lon": -1.05, "lat": 43.72}, "gplc_prix": null}]}
        """
        let stations = try PriceService.parseStations(Data(json.utf8), fuel: .gplc, from: dax)
        #expect(stations.count == 1)
        let first = try #require(stations.first)
        #expect(first.price == 1.079)
        #expect(first.town == "Dax")
        #expect(first.updated != nil)
        #expect(abs(first.distance - 1.11) < 0.05)
    }

    @Test("Aggregate stats are parsed")
    func parseStats() throws {
        let json = #"{"total_count": 4, "results": [{"average": 0.88325, "stations": 4}]}"#
        let stats = try PriceService.parseStats(Data(json.utf8))
        #expect(stats.average == 0.88325)
        #expect(stats.count == 4)
    }
}

@Suite("Town search")
struct AddressServiceTests {
    @Test("Municipality features become places")
    func parse() throws {
        let json = """
        {"features": [{"geometry": {"coordinates": [-0.500182, 43.891359]},
          "properties": {"name": "Mont-de-Marsan", "postcode": "40000", "context": "40, Landes"}}]}
        """
        let places = try AddressService.parse(Data(json.utf8))
        #expect(places == [Place(name: "Mont-de-Marsan", postcode: "40000", latitude: 43.891359, longitude: -0.500182)])
    }
}

@Suite("Alerts")
struct PriceAlertsTests {
    @Test("A drop is reported")
    func drop() {
        let message = PriceAlerts.message(for: report(2.199), previous: 2.229, threshold: nil, notifyOnDrop: true)
        #expect(message?.title.hasSuffix("goedkoper: \(2.199.formatted(.priceFormat))") == true)
    }

    @Test("Unchanged or rising prices stay quiet")
    func noDrop() {
        #expect(PriceAlerts.message(for: report(2.199), previous: 2.199, threshold: nil, notifyOnDrop: true) == nil)
        #expect(PriceAlerts.message(for: report(2.249), previous: 2.199, threshold: nil, notifyOnDrop: true) == nil)
    }

    @Test("Drop message: any lower price, nothing otherwise")
    func dropMessage() {
        #expect(PriceAlerts.dropMessage(for: report(2.198), previous: 2.199)?.title.hasPrefix("Gazole") == true)
        #expect(PriceAlerts.dropMessage(for: report(2.199), previous: 2.199) == nil)
        #expect(PriceAlerts.dropMessage(for: report(2.299), previous: 2.199) == nil)
        #expect(PriceAlerts.dropMessage(for: report(2.0), previous: nil) == nil)
    }

    @Test("Threshold fires only when crossed")
    func threshold() {
        #expect(PriceAlerts.message(for: report(2.09), previous: 2.15, threshold: 2.10, notifyOnDrop: false) != nil)
        #expect(PriceAlerts.message(for: report(2.08), previous: 2.09, threshold: 2.10, notifyOnDrop: false) == nil)
    }

    @Test("No stations, no alert")
    func empty() {
        #expect(PriceAlerts.message(for: report(), previous: 2.0, threshold: 3.0, notifyOnDrop: true) == nil)
    }
}

@Suite("ntfy")
struct NtfyTests {
    @Test("Publishes JSON with topic, text and click link to the server root")
    func request() throws {
        let config = NtfyConfig(server: "https://ntfy.sh", topic: " fuelwatch-abc ")
        let click = URL(string: "https://maps.apple.com/?ll=1,2")!
        let request = try NtfyService.request(title: "Gazole à 2,199 €", message: "Dax", click: click,
                                              tags: ["fuelpump"], config: config)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://ntfy.sh")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["topic"] as? String == "fuelwatch-abc")
        #expect(json["title"] as? String == "Gazole à 2,199 €")
        #expect(json["click"] as? String == click.absoluteString)
    }

    @Test("Incomplete config is rejected")
    func incomplete() {
        #expect(!NtfyConfig(server: "https://ntfy.sh", topic: "  ").isComplete)
        #expect(!NtfyConfig(server: "not a url", topic: "x").isComplete)
        #expect(NtfyConfig.randomTopic().hasPrefix("fuelwatch-"))
    }
}

@Suite("History")
struct HistoryStoreTests {
    @Test("Daily minimum per day, oldest first")
    func dailyMinimums() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 8))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 8))!
        let points = [
            PricePoint(date: day2, fuel: .gazole, cheapest: 2.20, average: nil, areaKey: "a"),
            PricePoint(date: day1, fuel: .gazole, cheapest: 2.25, average: nil, areaKey: "a"),
            PricePoint(date: day1.addingTimeInterval(3600), fuel: .gazole, cheapest: 2.21, average: nil, areaKey: "a"),
        ]
        let daily = HistoryStore.dailyMinimums(points, calendar: calendar)
        #expect(daily.map(\.cheapest) == [2.21, 2.20])
    }

    @Test("Recorded points survive a reload and are filtered by area")
    func persistence() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "fuelwatch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try await HistoryStore(fileURL: url).record([
            PricePoint(date: .now, fuel: .sp95, cheapest: 1.9, average: 1.95, areaKey: "a"),
            PricePoint(date: .now, fuel: .sp95, cheapest: 1.8, average: 1.85, areaKey: "b"),
        ])
        let reloaded = HistoryStore(fileURL: url)
        #expect(try await reloaded.latest(for: .sp95, areaKey: "a")?.cheapest == 1.9)
        #expect(try await reloaded.latest(for: .gazole, areaKey: "a") == nil)
    }
}

@Suite("Shortages")
struct ShortageTests {
    @Test("Filter asks for recent temporary shortages within the radius")
    func filter() {
        let filter = PriceService.shortageFilter(for: .gazole, around: dax, radiusKm: 20)
        #expect(filter.contains("within_distance(geom, geom'POINT(-1.05 43.71)', 20km)"))
        #expect(filter.contains("gazole_rupture_type = 'temporaire'"))
        #expect(filter.contains("gazole_rupture_debut >= now(days=-14)"))
    }

    @Test("Shortages are parsed with start date, closest first")
    func parse() throws {
        let json = """
        {"total_count": 3, "results": [
          {"id": 1, "adresse": "ROUTE DE TOSSE", "ville": "CASTETS", "geom": {"lon": -1.15, "lat": 43.88},
           "gazole_rupture_debut": "2026-11-06T16:51:26+00:00"},
          {"id": 2, "adresse": "1 RUE TEST", "ville": "DAX", "geom": {"lon": -1.05, "lat": 43.72},
           "gazole_rupture_debut": "2026-11-05T13:28:32+00:00"},
          {"id": 3, "adresse": "no location", "ville": "Dax", "gazole_rupture_debut": null}]}
        """
        let shortages = try PriceService.parseShortages(Data(json.utf8), fuel: .gazole, from: dax)
        #expect(shortages.map(\.stationID) == [2, 1])
        let first = try #require(shortages.first)
        #expect(first.town == "Dax")
        #expect(first.since == ISO8601DateFormatter().date(from: "2026-11-05T13:28:32+00:00"))
        #expect(first.mapsURL != nil)
    }

    @Test("Shortage dates don't leak into price parsing")
    func priceParsingIgnoresShortages() throws {
        let json = """
        {"results": [{"id": 1, "geom": {"lon": -1.05, "lat": 43.72}, "e85_prix": 0.869,
          "e85_maj": "2026-11-09T01:17:00+00:00", "sp95_rupture_debut": "2023-01-13T14:39:39+00:00"}]}
        """
        let stations = try PriceService.parseStations(Data(json.utf8), fuel: .e85, from: dax)
        #expect(stations.first?.updated == ISO8601DateFormatter().date(from: "2026-11-09T01:17:00+00:00"))
    }
}

@Suite("Shortage alerts")
struct ShortageAlertTests {
    private func shortage(_ id: Int, town: String, distance: Double, since: Date? = Date(timeIntervalSince1970: 1_800_000_000)) -> StationShortage {
        StationShortage(stationID: id, address: "1 Rue Test", town: town, latitude: 43.7, longitude: -1.05,
                        since: since, distance: distance)
    }

    private func report(_ fuel: FuelType, _ shortages: [StationShortage]) -> FuelReport {
        FuelReport(fuel: fuel, cheapest: [], average: nil, stationCount: 0, shortages: shortages)
    }

    @Test("Only shortages not seen before are new")
    func newOnly() {
        let castets = shortage(1, town: "Castets", distance: 20)
        let dax = shortage(2, town: "Dax", distance: 1)
        let known: Set = [PriceAlerts.shortageKey(castets, fuel: .gazole)]
        let new = PriceAlerts.newShortages(in: [report(.gazole, [dax, castets]), report(.e85, [])], known: known)
        #expect(new.count == 1)
        #expect(new.first?.fuel == .gazole)
        #expect(new.first?.shortages.map(\.stationID) == [2])
    }

    @Test("The same station running out again later is new; another fuel is separate")
    func keys() {
        let first = shortage(1, town: "Dax", distance: 1, since: Date(timeIntervalSince1970: 1_800_000_000))
        let again = shortage(1, town: "Dax", distance: 1, since: Date(timeIntervalSince1970: 1_800_100_000))
        #expect(PriceAlerts.shortageKey(first, fuel: .gazole) != PriceAlerts.shortageKey(again, fuel: .gazole))
        #expect(PriceAlerts.shortageKey(first, fuel: .gazole) != PriceAlerts.shortageKey(first, fuel: .sp95))
    }

    @Test("Message names the station, or the towns when there are several")
    func message() {
        let one = PriceAlerts.shortageMessage(fuel: .gazole, shortages: [shortage(1, town: "Dax", distance: 1.2)])
        #expect(one?.title == "Gazole is op bij Dax")
        #expect(one?.body.contains("Dax") == true)

        let many = PriceAlerts.shortageMessage(fuel: .e10, shortages: [
            shortage(1, town: "Dax", distance: 1), shortage(2, town: "Castets", distance: 20),
        ])
        #expect(many?.title == "E10 is op bij 2 stations")
        #expect(many?.body.contains("Castets") == true)
        #expect(PriceAlerts.shortageMessage(fuel: .e10, shortages: []) == nil)
    }
}
