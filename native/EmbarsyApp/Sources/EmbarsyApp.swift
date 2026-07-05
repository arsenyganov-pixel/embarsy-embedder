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

@main
struct EmbarsyApp: App {
    @NSApplicationDelegateAdaptor(EmbarsyAppDelegate.self) private var appDelegate
    @StateObject private var store = EmbarsyStore()

    var body: some Scene {
        WindowGroup("Embarsy", id: EmbarsyWindowID.main) {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 760, minHeight: 520)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    await store.startStackIfNeededOnLaunch()
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
