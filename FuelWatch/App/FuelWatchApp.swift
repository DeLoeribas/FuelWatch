import SwiftUI
import UserNotifications

@main
struct FuelWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = FuelStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

/// The icon and cheapest price shown in the menu bar.
private struct MenuBarLabel: View {
    let store: FuelStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "fuelpump.fill")
            if let text = store.menuBarText {
                Text(text).monospacedDigit()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Task { await PriceAlerts.requestAuthorization() }
    }

    /// Show alerts even while the menu is open, which makes the app frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
