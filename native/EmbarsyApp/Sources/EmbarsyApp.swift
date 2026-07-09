import AppKit
import SwiftUI

enum EmbarsyWindowID {
    static let main = "main"
}

/// Forces the whole app (windows, popovers, alerts, menu-bar popup) to the dark
/// appearance the Embarsy tokens are authored for, so light mode never leaks in.
final class EmbarsyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

/// Dev/screenshot hooks (release-notes tooling; inert in normal launches):
/// `EMBARSY_START_TAB=status|monitoring|activity|content|settings|howto` opens on that tab,
/// `EMBARSY_WINDOW=862x1533` pins the window content to an exact point size.
enum EmbarsyLaunchOverrides {
    static var startTab: AppTab? {
        switch ProcessInfo.processInfo.environment["EMBARSY_START_TAB"]?.lowercased() {
        case "status": .status
        case "monitoring": .monitoring
        case "activity": .activity
        case "content": .content
        case "settings": .settings
        case "howto": .howto
        default: nil
        }
    }

    static var windowSize: CGSize? {
        guard let raw = ProcessInfo.processInfo.environment["EMBARSY_WINDOW"] else { return nil }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 400, parts[1] >= 300 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    /// `EMBARSY_STILL=1` freezes decorative animations (the hero mark's draw loop) so
    /// screenshots never catch them mid-cycle.
    static let stillMode = ProcessInfo.processInfo.environment["EMBARSY_STILL"] == "1"

    /// `EMBARSY_MONITOR_SCALE=15m|1h|6h|24h|7d` pre-selects the Monitoring time range.
    static var monitoringScale: MonitoringScale? {
        switch ProcessInfo.processInfo.environment["EMBARSY_MONITOR_SCALE"]?.lowercased() {
        case "15m": .minutes15
        case "1h": .hour1
        case "6h": .hours6
        case "24h": .hours24
        case "7d": .days7
        default: nil
        }
    }
}

@main
struct EmbarsyApp: App {
    @NSApplicationDelegateAdaptor(EmbarsyAppDelegate.self) private var appDelegate
    @StateObject private var store = EmbarsyStore()

    var body: some Scene {
        WindowGroup("Embarsy", id: EmbarsyWindowID.main) {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 760, minHeight: 520)
                .frame(
                    width: EmbarsyLaunchOverrides.windowSize?.width,
                    height: EmbarsyLaunchOverrides.windowSize?.height
                )
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    if let tab = EmbarsyLaunchOverrides.startTab {
                        store.selectedTab = tab
                    }
                    if let scale = EmbarsyLaunchOverrides.monitoringScale {
                        store.monitoring.scale = scale
                    }
                    await store.startStackIfNeededOnLaunch()
                    // Dev/verification hook (inert normally): EMBARSY_DEV_HARD_RESET=1
                    // waits for the stack to come up, then runs the exact code path of
                    // Settings → "Remove Components and Clear Secrets" → "Remove
                    // Everything" — used to verify removal end-to-end against a RUNNING
                    // stack (locked DB files, live processes).
                    if ProcessInfo.processInfo.environment["EMBARSY_DEV_HARD_RESET"] == "1" {
                        for _ in 0..<60 where store.aggregateStatus != .running {
                            try? await Task.sleep(for: .seconds(1))
                        }
                        await store.removeComponentsAndLocalSecrets()
                    }
                }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        } label: {
            MenuBarIconView(status: store.aggregateStatus)
        }
        .menuBarExtraStyle(.window)
    }
}
