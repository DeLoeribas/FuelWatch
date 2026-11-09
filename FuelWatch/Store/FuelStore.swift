import Foundation
import Observation
import ServiceManagement

/// App state: user settings, the latest prices, history and the refresh schedule.
@MainActor
@Observable
final class FuelStore {
    // MARK: - Settings

    var place: Place? {
        didSet { save(place, forKey: Keys.place); settingsChanged() }
    }
    var radiusKm: Int {
        didSet { defaults.set(radiusKm, forKey: Keys.radius); settingsChanged() }
    }
    var fuels: Set<FuelType> {
        didSet { save(fuels.map(\.rawValue), forKey: Keys.fuels); settingsChanged() }
    }
    /// The fuel whose cheapest price is shown in the menu bar.
    var menuBarFuel: FuelType {
        didSet { defaults.set(menuBarFuel.rawValue, forKey: Keys.menuBarFuel) }
    }
    var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: Keys.refreshMinutes); restartSchedule() }
    }
    var notifyOnDrop: Bool {
        didSet { defaults.set(notifyOnDrop, forKey: Keys.notifyOnDrop) }
    }
    /// Per-fuel "notify me below this price" values.
    var thresholds: [FuelType: Double] {
        didSet { save(Dictionary(uniqueKeysWithValues: thresholds.map { ($0.key.rawValue, $0.value) }), forKey: Keys.thresholds) }
    }

    /// Notify when a station in the area runs out of a tracked fuel.
    var notifyOnShortage: Bool {
        didSet { defaults.set(notifyOnShortage, forKey: Keys.notifyOnShortage) }
    }
    /// Also send shortage alerts to the phone (price drops always go there when ntfy is on).
    var ntfyShortages: Bool {
        didSet { defaults.set(ntfyShortages, forKey: Keys.ntfyShortages) }
    }

    /// Also send alerts to a phone through ntfy.
    var ntfyEnabled: Bool {
        didSet { defaults.set(ntfyEnabled, forKey: Keys.ntfyEnabled) }
    }
    var ntfyConfig: NtfyConfig {
        didSet {
            defaults.set(ntfyConfig.server, forKey: Keys.ntfyServer)
            defaults.set(ntfyConfig.topic, forKey: Keys.ntfyTopic)
        }
    }

    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                errorMessage = error.localizedDescription
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    // MARK: - State

    private(set) var reports: [FuelType: FuelReport] = [:]
    /// Daily cheapest prices for the last month, per fuel.
    private(set) var history: [FuelType: [DailyPrice]] = [:]
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    var errorMessage: String?

    /// Fuels in a stable display order.
    var orderedFuels: [FuelType] { FuelType.allCases.filter(fuels.contains) }

    /// Text for the menu bar, e.g. "2,199".
    var menuBarText: String? {
        guard let price = reports[menuBarFuel]?.bestPrice else { return nil }
        return price.formatted(.number.precision(.fractionLength(3)))
    }

    /// Cheapest price on the last day before today with history, to show the daily change.
    func previousDayPrice(for fuel: FuelType) -> Double? {
        let today = Calendar.current.startOfDay(for: .now)
        return history[fuel]?.last { $0.day < today }?.cheapest
    }

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let prices: PriceService
    private let historyStore: HistoryStore
    private let ntfy: NtfyService
    private var scheduleTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         prices: PriceService = PriceService(),
         historyStore: HistoryStore = HistoryStore(),
         ntfy: NtfyService = NtfyService()) {
        self.defaults = defaults
        self.prices = prices
        self.historyStore = historyStore
        self.ntfy = ntfy

        place = Self.load(Place.self, from: defaults, forKey: Keys.place)
        radiusKm = defaults.object(forKey: Keys.radius) as? Int ?? 15
        fuels = Self.load([String].self, from: defaults, forKey: Keys.fuels)
            .map { Set($0.compactMap(FuelType.init(rawValue:))) } ?? FuelType.defaultSelection
        menuBarFuel = defaults.string(forKey: Keys.menuBarFuel).flatMap(FuelType.init(rawValue:)) ?? .gazole
        refreshMinutes = defaults.object(forKey: Keys.refreshMinutes) as? Int ?? 60
        notifyOnDrop = defaults.object(forKey: Keys.notifyOnDrop) as? Bool ?? true
        thresholds = (Self.load([String: Double].self, from: defaults, forKey: Keys.thresholds) ?? [:])
            .reduce(into: [:]) { result, entry in
                if let fuel = FuelType(rawValue: entry.key) { result[fuel] = entry.value }
            }
        notifyOnShortage = defaults.object(forKey: Keys.notifyOnShortage) as? Bool ?? true
        ntfyShortages = defaults.bool(forKey: Keys.ntfyShortages)
        ntfyEnabled = defaults.bool(forKey: Keys.ntfyEnabled)
        ntfyConfig = NtfyConfig(server: defaults.string(forKey: Keys.ntfyServer) ?? NtfyConfig.defaultServer,
                                topic: defaults.string(forKey: Keys.ntfyTopic) ?? "")

        restartSchedule()
    }

    // MARK: - Refreshing

    /// Fetches current prices, records history and sends alerts.
    func refresh() async {
        guard let place, !fuels.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let radiusKm = radiusKm
        let areaKey = HistoryStore.areaKey(for: place, radiusKm: radiusKm)
        do {
            let fetched = try await prices.reports(for: orderedFuels, around: place, radiusKm: radiusKm)
            // The area may have changed while fetching; drop stale results.
            guard self.place == place, self.radiusKm == radiusKm else { return }

            await sendAlerts(for: fetched, areaKey: areaKey)
            await sendShortageAlerts(for: fetched, areaKey: areaKey)

            let now = Date.now
            let points = fetched.compactMap { report in
                report.bestPrice.map {
                    PricePoint(date: now, fuel: report.fuel, cheapest: $0, average: report.average, areaKey: areaKey)
                }
            }
            try await historyStore.record(points)

            reports = Dictionary(uniqueKeysWithValues: fetched.map { ($0.fuel, $0) })
            for fuel in orderedFuels {
                history[fuel] = try await historyStore.daily(for: fuel, areaKey: areaKey, days: 30)
            }
            lastUpdated = now
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sendAlerts(for fetched: [FuelReport], areaKey: String) async {
        for report in fetched {
            let previous = try? await historyStore.latest(for: report.fuel, areaKey: areaKey)?.cheapest
            if let message = PriceAlerts.message(for: report,
                                                 previous: previous,
                                                 threshold: thresholds[report.fuel],
                                                 notifyOnDrop: notifyOnDrop && previous != nil) {
                try? await PriceAlerts.post(title: message.title, body: message.body)
            }
            // The iPhone only hears about drops, whatever the Mac alert settings are.
            if ntfyEnabled, ntfyConfig.isComplete, let drop = PriceAlerts.dropMessage(for: report, previous: previous) {
                do {
                    try await ntfy.send(title: drop.title, message: drop.body,
                                        click: report.cheapest.first?.mapsURL, to: ntfyConfig)
                } catch {
                    errorMessage = "Versturen naar ntfy lukte niet: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Notifies about stations that ran out since the previous refresh.
    /// The first refresh in an area only records what's already out, so a new town doesn't cause a burst of alerts.
    private func sendShortageAlerts(for fetched: [FuelReport], areaKey: String) async {
        let current = Set(fetched.flatMap { report in
            report.shortages.map { PriceAlerts.shortageKey($0, fuel: report.fuel) }
        })
        let isSameArea = defaults.string(forKey: Keys.knownShortagesArea) == areaKey
        let known = Set(defaults.stringArray(forKey: Keys.knownShortages) ?? [])
        defaults.set(Array(current), forKey: Keys.knownShortages)
        defaults.set(areaKey, forKey: Keys.knownShortagesArea)
        guard isSameArea else { return }

        for (fuel, shortages) in PriceAlerts.newShortages(in: fetched, known: known) {
            guard let message = PriceAlerts.shortageMessage(fuel: fuel, shortages: shortages) else { continue }
            if notifyOnShortage {
                try? await PriceAlerts.post(title: message.title, body: message.body)
            }
            if ntfyEnabled, ntfyShortages, ntfyConfig.isComplete {
                do {
                    try await ntfy.send(title: message.title, message: message.body,
                                        click: shortages.first?.mapsURL, tags: ["warning"], to: ntfyConfig)
                } catch {
                    errorMessage = "Versturen naar ntfy lukte niet: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Sends a test message with the current cheapest price, so the phone setup can be checked.
    func sendNtfyTest() async throws {
        let summary = orderedFuels.compactMap { fuel in
            reports[fuel]?.bestPrice.map { "\(fuel.displayName) \($0.formatted(.priceFormat))" }
        }
        let message = summary.isEmpty
            ? "Hier komen de meldingen van FuelWatch binnen."
            : "Nu het goedkoopst rond \(place?.name ?? "je woonplaats"): " + summary.joined(separator: ", ")
        try await ntfy.send(title: "FuelWatch-test", message: message, to: ntfyConfig)
    }

    /// Refreshes now and then every `refreshMinutes`.
    private func restartSchedule() {
        scheduleTask?.cancel()
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let minutes = self.refreshMinutes
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    private func settingsChanged() {
        reports = [:]
        history = [:]
        restartSchedule()
    }

    // MARK: - Persistence

    private enum Keys {
        static let place = "place"
        static let radius = "radiusKm"
        static let fuels = "fuels"
        static let menuBarFuel = "menuBarFuel"
        static let refreshMinutes = "refreshMinutes"
        static let notifyOnDrop = "notifyOnDrop"
        static let thresholds = "thresholds"
        static let notifyOnShortage = "notifyOnShortage"
        static let ntfyShortages = "ntfyShortages"
        static let knownShortages = "knownShortages"
        static let knownShortagesArea = "knownShortagesArea"
        static let ntfyEnabled = "ntfyEnabled"
        static let ntfyServer = "ntfyServer"
        static let ntfyTopic = "ntfyTopic"
    }

    private func save<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, forKey key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
