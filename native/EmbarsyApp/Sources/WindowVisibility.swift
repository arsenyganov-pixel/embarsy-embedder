import AppKit
import Combine

/// Tracks whether any regular app window is actually visible on screen (not closed,
/// not minimized, not fully covered by other apps). Poll loops and decorative
/// animations consult this so the app stops doing per-second work nobody can see —
/// the menu-bar status window (level != .normal) intentionally doesn't count.
@MainActor
final class WindowVisibility: ObservableObject {
    static let shared = WindowVisibility()

    @Published private(set) var isMainWindowVisible = true

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
            NSWindow.didBecomeKeyNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        refresh()
    }

    /// Snapshot check, also usable directly from poll loops.
    static var mainWindowVisible: Bool {
        NSApp?.windows.contains { window in
            window.isVisible
                && window.level == .normal
                && window.occlusionState.contains(.visible)
        } ?? true
    }

    private func refresh() {
        let visible = Self.mainWindowVisible
        if visible != isMainWindowVisible {
            isMainWindowVisible = visible
        }
    }
}
