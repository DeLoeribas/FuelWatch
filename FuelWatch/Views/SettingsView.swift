import SwiftUI

/// Settings window: search area, fuels, refresh interval and alerts.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Gebied", systemImage: "mappin.and.ellipse") { AreaSettings() }
            Tab("Brandstoffen", systemImage: "fuelpump") { FuelSettings() }
            Tab("iPhone", systemImage: "iphone") { PhoneSettings() }
            Tab("Algemeen", systemImage: "gearshape") { GeneralSettings() }
        }
        .frame(width: 460)
        .scenePadding()
    }
}

private struct AreaSettings: View {
    @Environment(FuelStore.self) private var store
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searchError: String?

    private let addresses = AddressService()

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                LabeledContent("Huidige plaats") {
                    if let place = store.place {
                        Text("\(place.name) (\(place.postcode))")
                    } else {
                        Text("Geen").foregroundStyle(.secondary)
                    }
                }
                TextField("Zoek plaats of postcode", text: $query, prompt: Text("bijv. Dax of 40100"))
                if let searchError {
                    Text(searchError).font(.caption).foregroundStyle(.orange)
                }
                ForEach(results, id: \.self) { place in
                    Button {
                        store.place = place
                        query = ""
                        results = []
                    } label: {
                        HStack {
                            Text(place.name)
                            Spacer()
                            Text(place.postcode).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                LabeledContent("Straal: \(store.radiusKm) km") {
                    Slider(value: Binding(get: { Double(store.radiusKm) },
                                          set: { store.radiusKm = Int($0) }),
                           in: 5...50, step: 5)
                }
            } footer: {
                Text("Als je de plaats of straal wijzigt, begint een nieuwe prijsgeschiedenis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: query) {
            // Debounce typing before hitting the address API.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                results = try await addresses.searchTowns(query)
                searchError = nil
            } catch is CancellationError {
            } catch {
                searchError = error.localizedDescription
            }
        }
    }
}

private struct FuelSettings: View {
    @Environment(FuelStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Volgen") {
                ForEach(FuelType.allCases) { fuel in
                    HStack {
                        Toggle(fuel.displayName, isOn: Binding(
                            get: { store.fuels.contains(fuel) },
                            set: { isOn in
                                if isOn { store.fuels.insert(fuel) } else { store.fuels.remove(fuel) }
                            }))
                        Spacer()
                        ThresholdField(fuel: fuel)
                            .disabled(!store.fuels.contains(fuel))
                    }
                }
            }
            Section {
                Picker("Toon in menubalk", selection: $store.menuBarFuel) {
                    ForEach(FuelType.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Meld het als de laagste prijs daalt", isOn: $store.notifyOnDrop)
                Toggle("Meld het als een station in de buurt een brandstof niet meer heeft", isOn: $store.notifyOnShortage)
            } footer: {
                Text("Vul naast een brandstof een alertprijs in om een melding te krijgen zodra het goedkoopste station daaronder zakt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Optional "alert below" price for one fuel.
private struct ThresholdField: View {
    @Environment(FuelStore.self) private var store
    let fuel: FuelType

    var body: some View {
        TextField("Alert onder", value: Binding(
            get: { store.thresholds[fuel] },
            set: { store.thresholds[fuel] = $0 }),
                  format: .number.precision(.fractionLength(3)),
                  prompt: Text("Alert onder €"))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 110)
    }
}

/// Sends alerts to the ntfy app on a phone.
private struct PhoneSettings: View {
    @Environment(FuelStore.self) private var store
    @State private var testStatus: String?
    @State private var isSending = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Stuur prijsdalingen naar mijn iPhone via ntfy", isOn: $store.ntfyEnabled)
                Toggle("Stuur ook een bericht als een brandstof op is", isOn: $store.ntfyShortages)
                    .disabled(!store.ntfyEnabled)
                TextField("Server", text: $store.ntfyConfig.server, prompt: Text(NtfyConfig.defaultServer))
                HStack {
                    TextField("Topic", text: $store.ntfyConfig.topic, prompt: Text("je-topic-naam"))
                    Button("Genereer") { store.ntfyConfig.topic = NtfyConfig.randomTopic() }
                }
                HStack {
                    Button("Stuur testbericht") {
                        Task {
                            isSending = true
                            defer { isSending = false }
                            do {
                                try await store.sendNtfyTest()
                                testStatus = "Verstuurd. Kijk op je iPhone."
                            } catch {
                                testStatus = error.localizedDescription
                            }
                        }
                    }
                    .disabled(!store.ntfyConfig.isComplete || isSending)
                    if let testStatus {
                        Text(testStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Je iPhone krijgt een bericht als de laagste prijs van een brandstof daalt en, als je dat aanzet, als een station in de buurt een brandstof niet meer heeft. Installeer de ntfy-app op je iPhone en abonneer je op hetzelfde topic. Op ntfy.sh kan iedereen die de naam van een topic kent de berichten lezen, dus kies een naam die moeilijk te raden is. Tik op een melding om het station in Kaarten te openen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettings: View {
    @Environment(FuelStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Picker("Prijzen controleren", selection: $store.refreshMinutes) {
                Text("Elke 30 minuten").tag(30)
                Text("Elk uur").tag(60)
                Text("Elke 3 uur").tag(180)
                Text("Elke 6 uur").tag(360)
            }
            Toggle("Open bij inloggen", isOn: $store.launchAtLogin)
            LabeledContent("Gegevens") {
                Link("prix-carburants.gouv.fr", destination: URL(string: "https://www.prix-carburants.gouv.fr")!)
            }
        }
        .formStyle(.grouped)
    }
}
