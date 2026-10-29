import Charts
import SwiftUI

/// The window that drops down from the menu bar icon.
struct MenuView: View {
    @Environment(FuelStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if store.place == nil {
                ContentUnavailableView {
                    Label("Kies je woonplaats", systemImage: "mappin.and.ellipse")
                } description: {
                    Text("FuelWatch zoekt de goedkoopste tankstations rond een plaats of postcode.")
                } actions: {
                    Button("Open Instellingen…", action: showSettings)
                }
            } else if store.fuels.isEmpty {
                ContentUnavailableView("Geen brandstoffen gekozen", systemImage: "fuelpump",
                                       description: Text("Kies in Instellingen welke brandstoffen je wilt volgen."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.orderedFuels) { fuel in
                            FuelSection(fuel: fuel)
                        }
                    }
                }
                .frame(maxHeight: 560)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Brandstofprijzen").font(.headline)
                if let place = store.place {
                    Text("Binnen \(store.radiusKm) km van \(place.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let updated = store.lastUpdated {
                Text("Bijgewerkt om \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Vernieuw", systemImage: "arrow.clockwise") {
                Task { await store.refresh() }
            }
            .disabled(store.isRefreshing || store.place == nil)
            Spacer()
            Button("Instellingen…", systemImage: "gearshape", action: showSettings)
            Button("Stop", systemImage: "power") { NSApp.terminate(nil) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}

/// Cheapest price, daily change, a month's trend and the cheapest stations for one fuel.
private struct FuelSection: View {
    @Environment(FuelStore.self) private var store
    let fuel: FuelType

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                summary
                if let history = store.history[fuel], history.count >= 2 {
                    TrendChart(points: history)
                }
                if let report = store.reports[fuel] {
                    ForEach(report.cheapest.prefix(3)) { station in
                        StationRow(station: station, isCheapest: station.price == report.bestPrice)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var summary: some View {
        let report = store.reports[fuel]
        HStack(alignment: .firstTextBaseline) {
            Text(fuel.displayName).font(.headline)
            Spacer()
            if let best = report?.bestPrice {
                if let previous = store.previousDayPrice(for: fuel) {
                    ChangeBadge(change: best - previous)
                }
                Text(best.formatted(.priceFormat))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            } else if report != nil {
                Text("Geen station binnen \(store.radiusKm) km")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("…").foregroundStyle(.secondary)
            }
        }
        if let report, let average = report.average {
            Text("Gemiddeld \(average.formatted(.priceFormat)) bij \(report.stationCount) stations")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Change since yesterday: green when cheaper, red when dearer.
private struct ChangeBadge: View {
    let change: Double

    var body: some View {
        if abs(change) >= 0.0005 {
            Label(abs(change).formatted(.priceFormat), systemImage: change < 0 ? "arrow.down" : "arrow.up")
                .font(.caption.monospacedDigit())
                .foregroundStyle(change < 0 ? .green : .red)
                .help("Verschil met de laagste prijs van gisteren")
        }
    }
}

/// Sparkline of the cheapest price per day.
private struct TrendChart: View {
    let points: [DailyPrice]

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("Dag", point.day, unit: .day), y: .value("Prijs", point.cheapest))
                .interpolationMethod(.monotone)
            PointMark(x: .value("Dag", point.day, unit: .day), y: .value("Prijs", point.cheapest))
                .symbolSize(12)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) {
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .frame(height: 70)
    }
}

/// One station: address, distance, price and how fresh the price is. Click to open in Maps.
private struct StationRow: View {
    let station: StationPrice
    let isCheapest: Bool

    var body: some View {
        Button {
            if let url = station.mapsURL { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(station.town).lineLimit(1)
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(station.price.formatted(.priceFormat))
                    .monospacedDigit()
                    .fontWeight(isCheapest ? .semibold : .regular)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toon in Kaarten")
    }

    private var details: String {
        var parts = [station.address, "\(station.distance.formatted(.number.precision(.fractionLength(1)))) km"]
        if let updated = station.updated {
            parts.append(updated.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}
